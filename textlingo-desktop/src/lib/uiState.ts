import { useCallback, useEffect, useSyncExternalStore } from "react";
import { invoke } from "@tauri-apps/api/core";

/**
 * Durable UI state for the article learning page.
 *
 * Reader preferences are global: one value shared by every article. Rust
 * (`ui_state.json`, via `get_ui_state` / `set_ui_state`) is the source of
 * truth. localStorage is only a synchronous read cache so first paint has
 * something before the async backend hydrate resolves — in packaged Tauri
 * builds the webview origin (`tauri://localhost`, WKWebView custom schemes)
 * has no disk-backed localStorage bucket, so localStorage alone never
 * survives a restart.
 *
 * Values are derived from the store on every render (instead of reload/persist
 * effects), which eliminates the class of effect-ordering bugs where switching
 * articles persisted article A's state under article B's key.
 *
 * The backend file is dedicated to UI state (separate from config.json) and
 * mutex-serialized per read-modify-write cycle, so overlapping persists are
 * safe and UI writes can never clobber model/API configuration.
 */

export const UI_VIEW_MODE_KEY = "textlingo_view_mode";
export const UI_SHOW_FULL_SUBTITLES_KEY = "textlingo_show_full_subtitles";
export const UI_FONT_SIZE_KEY = "textlingo_font_size";

export type UiViewMode = "original" | "bilingual" | "translation";

const VIEW_MODES: readonly string[] = ["original", "bilingual", "translation"];

export const FONT_SIZE_DEFAULT = 18;
export const FONT_SIZE_MIN = 12;
export const FONT_SIZE_MAX = 32;

// Keys written by earlier localStorage-only builds. Migrated into the backend
// store on first hydrate (see migrateLocalCacheToBackend).
const LEGACY_KEY_MAP: Record<string, string[]> = {
  [UI_VIEW_MODE_KEY]: ["article-reader-view-mode"],
  [UI_SHOW_FULL_SUBTITLES_KEY]: ["video-player-show-full-subtitles"],
  [UI_FONT_SIZE_KEY]: ["article-reader-font-size"],
};

const MANAGED_KEYS = [UI_VIEW_MODE_KEY, UI_SHOW_FULL_SUBTITLES_KEY, UI_FONT_SIZE_KEY];

// Retry policy for failed persists: bounded, so a permanently broken backend
// cannot spin IPC attempts (and console spam) forever.
const MAX_PERSIST_RETRIES = 3;
const RETRY_BASE_DELAY_MS = 1000;

function safeStorageGet(key: string): string | null {
  try {
    if (typeof window === "undefined" || !window.localStorage) return null;
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function safeStorageSet(key: string, value: string): void {
  try {
    if (typeof window === "undefined" || !window.localStorage) return;
    window.localStorage.setItem(key, value);
  } catch {
    // Storage may throw (private mode, blocked storage) — the backend is the
    // source of truth, so a cache write failure is non-fatal.
  }
}

function safeStorageRemove(key: string): void {
  try {
    if (typeof window === "undefined" || !window.localStorage) return;
    window.localStorage.removeItem(key);
  } catch {
    // Non-fatal; the key is simply left behind.
  }
}

// --- module-level store -----------------------------------------------------

let cache: Record<string, string> = {};
const listeners = new Set<() => void>();

/**
 * Keys written locally at any point since module load. Hydration responses
 * are older than these writes by construction (single client), so merging
 * must skip them — otherwise a slow get_ui_state overwrites a setting the
 * user changed while the request was in flight.
 */
const locallyWritten = new Set<string>();

/** Values changed locally but not yet confirmed persisted by the backend. */
let unsynced: Record<string, string | null> = {};
/** Legacy keys migrated but not yet confirmed persisted — see below. */
let migratedLegacy: { legacy: string; target: string }[] = [];
let persistInFlight = false;
let persistRetryCount = 0;
let visibilityHookInstalled = false;

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function notify(): void {
  listeners.forEach((listener) => {
    try {
      listener();
    } catch {
      // Ignore listener errors; other subscribers must still run.
    }
  });
}

function readLegacy(baseKey: string): string | null {
  const legacyKeys = LEGACY_KEY_MAP[baseKey];
  if (!legacyKeys) return null;
  for (const key of legacyKeys) {
    const value = safeStorageGet(key);
    if (value !== null) return value;
  }
  return null;
}

/** Resolve cache → read cache → legacy → fallback. Runs on every render. */
function readEffective(baseKey: string, fallback: string): string {
  const cached = cache[baseKey];
  if (cached !== undefined) return cached;
  const stored = safeStorageGet(baseKey);
  if (stored !== null) return stored;
  return readLegacy(baseKey) ?? fallback;
}

/** Write the single global key, update cache + read cache, notify, persist. */
function writeGlobal(baseKey: string, value: string): void {
  cache[baseKey] = value;
  safeStorageSet(baseKey, value);
  locallyWritten.add(baseKey);
  unsynced[baseKey] = value;
  notify();
  // Direct write: these controls change infrequently, so persist immediately
  // instead of debouncing — a debounced (or visibilitychange-flushed) write
  // can still be abandoned during application shutdown.
  void persistUnsynced();
}

// --- backend sync -----------------------------------------------------------

let hydratePromise: Promise<void> | null = null;

function ensureVisibilityHook(): void {
  if (visibilityHookInstalled || typeof document === "undefined") return;
  visibilityHookInstalled = true;
  // Best-effort only: re-attempt any unconfirmed writes when the page hides.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden" && Object.keys(unsynced).length > 0) {
      void persistUnsynced();
    }
  });
}

/**
 * Persist every unconfirmed key. Overlapping calls are safe (backend merges
 * per key under a mutex); concurrent invocations are coalesced into one
 * flight, and a newer write that lands mid-flight stays in `unsynced`.
 */
async function persistUnsynced(): Promise<void> {
  ensureVisibilityHook();
  if (persistInFlight) return;
  const snapshot = { ...unsynced };
  const keys = Object.keys(snapshot);
  if (keys.length === 0) return;
  persistInFlight = true;
  let error: unknown = null;
  try {
    await invoke("set_ui_state", { updates: snapshot });
  } catch (e) {
    error = e;
  }
  persistInFlight = false;
  if (error === null) {
    // Drop only keys that didn't change under us; newer values stay queued.
    for (const key of keys) {
      if (unsynced[key] === snapshot[key]) {
        delete unsynced[key];
      }
    }
    // Legacy entries are dropped only now that their replacements are
    // confirmed in the backend — never before persistence succeeds.
    if (migratedLegacy.length > 0) {
      migratedLegacy = migratedLegacy.filter(({ legacy, target }) => {
        if (target in unsynced) return true;
        safeStorageRemove(legacy);
        return false;
      });
    }
    persistRetryCount = 0;
    // A newer write may have landed mid-flight (its persist call bailed on
    // persistInFlight) — flush it now instead of leaving it unsynced.
    if (Object.keys(unsynced).length > 0) {
      void persistUnsynced();
    }
    return;
  }
  if (persistRetryCount < MAX_PERSIST_RETRIES) {
    persistRetryCount += 1;
    const delay = RETRY_BASE_DELAY_MS * 2 ** (persistRetryCount - 1);
    setTimeout(() => {
      void persistUnsynced();
    }, delay);
    return;
  }
  console.error(
    `[uiState] set_ui_state failed after ${MAX_PERSIST_RETRIES} retries; ` +
      "values remain visible this session and will sync on the next change:",
    error,
  );
  persistRetryCount = 0;
}

/**
 * Push localStorage-only values (legacy keys and any managed global key the
 * backend doesn't know yet) into the backend. This is what makes migration
 * real instead of a fallback read: after this runs, the backend holds every
 * known setting.
 */
function migrateLocalCacheToBackend(backendKeys: Set<string>): void {
  // Phase 1 (read-only): snapshot every storage entry first. Mutating
  // storage while iterating by index shifts later entries down and silently
  // skips them, so no writes may happen inside the enumeration loop.
  let entries: [string, string][] = [];
  try {
    if (typeof window === "undefined" || !window.localStorage) return;
    const storage = window.localStorage;
    const total = storage.length;
    for (let i = 0; i < total; i++) {
      const key = storage.key(i);
      if (!key) continue;
      const value = safeStorageGet(key);
      if (value === null) continue;
      entries.push([key, value]);
    }
  } catch {
    // Storage enumeration may throw — migration is best-effort.
    return;
  }
  // Phase 2: compute the migration purely from the snapshot, then apply.
  // Classify first, apply in fixed order — canonical global keys, then legacy
  // aliases — so the winner never depends on localStorage insertion order.
  try {
    const legacyMap: Record<string, string> = {};
    for (const [newKey, legacyKeys] of Object.entries(LEGACY_KEY_MAP)) {
      for (const legacy of legacyKeys) legacyMap[legacy] = newKey;
    }
    const canonicalGlobals: [target: string, value: string][] = [];
    const legacyAliases: [target: string, value: string, legacy: string][] = [];
    for (const [key, value] of entries) {
      if (key in legacyMap) {
        legacyAliases.push([legacyMap[key], value, key]);
        continue;
      }
      if (MANAGED_KEYS.includes(key)) {
        canonicalGlobals.push([key, value]);
      }
    }
    const migrate: Record<string, string> = {};
    const claimGlobal = (target: string, value: string) => {
      // Migrate when the backend lacks the key.
      if (backendKeys.has(target) || target in migrate) return;
      migrate[target] = value;
      cache[target] = value;
      safeStorageSet(target, value);
    };
    // Canonical keys first: they always beat legacy aliases for the same
    // target, no matter which was inserted into storage first.
    for (const [target, value] of canonicalGlobals) claimGlobal(target, value);
    for (const [target, value, legacy] of legacyAliases) {
      if (backendKeys.has(target)) {
        // Backend canonical is already authoritative — the alias is residue.
        safeStorageRemove(legacy);
        continue;
      }
      if (target in migrate) {
        // Lost to a same-session claim (canonicals run first): drop the
        // alias once the winner is confirmed persisted.
        migratedLegacy.push({ legacy, target });
        continue;
      }
      claimGlobal(target, value);
      migratedLegacy.push({ legacy, target });
    }
    if (Object.keys(migrate).length > 0) {
      for (const [key, value] of Object.entries(migrate)) {
        unsynced[key] = value;
        locallyWritten.add(key);
      }
      notify();
      void persistUnsynced();
    }
  } catch {
    // Best-effort.
  }
}

function ensureHydrate(): Promise<void> {
  if (hydratePromise) return hydratePromise;
  hydratePromise = (async () => {
    const state = await invoke<Record<string, string>>("get_ui_state");
    const backendKeys = new Set<string>();
    if (state && typeof state === "object") {
      let changed = false;
      for (const [key, value] of Object.entries(state)) {
        if (typeof value !== "string") continue;
        backendKeys.add(key);
        // Skip anything the user touched locally: the backend snapshot
        // predates those writes, and merging would restore stale values
        // over the newer user action.
        if (locallyWritten.has(key)) continue;
        if (cache[key] !== value) {
          cache[key] = value;
          safeStorageSet(key, value);
          changed = true;
        }
      }
      if (changed) notify();
    }
    migrateLocalCacheToBackend(backendKeys);
  })().catch(() => {
    // Null the memo so a later mount retries (the IPC bridge may not be
    // ready at first bundle-eval / first-mount time).
    hydratePromise = null;
  });
  return hydratePromise;
}

/** Test-only: clear the module-level cache so tests don't bleed into each other. */
export function resetUiStateForTests(): void {
  cache = {};
  unsynced = {};
  locallyWritten.clear();
  migratedLegacy = [];
  persistInFlight = false;
  persistRetryCount = 0;
  hydratePromise = null;
}

// --- hooks ------------------------------------------------------------------

/** String-valued global UI state with the given fallback. */
function useUiState(baseKey: string, fallback: string): [string, (value: string) => void] {
  useEffect(() => {
    void ensureHydrate();
  }, []);

  const value = useSyncExternalStore(subscribe, () => readEffective(baseKey, fallback));

  const setValue = useCallback(
    (next: string) => {
      writeGlobal(baseKey, next);
    },
    [baseKey],
  );

  return [value, setValue];
}

function clampFontSize(value: number): number {
  if (!Number.isFinite(value)) return FONT_SIZE_DEFAULT;
  return Math.min(FONT_SIZE_MAX, Math.max(FONT_SIZE_MIN, Math.trunc(value)));
}

function parseFontSize(raw: string): number {
  return clampFontSize(Number(raw));
}

function parseViewMode(raw: string): UiViewMode {
  return (VIEW_MODES as string[]).includes(raw) ? (raw as UiViewMode) : "original";
}

function parseBoolean(raw: string, fallback: boolean): boolean {
  if (raw === "true") return true;
  if (raw === "false") return false;
  return fallback;
}

type SetStateAction<T> = T | ((prev: T) => T);

function resolveAction<T>(action: SetStateAction<T>, current: T): T {
  return typeof action === "function"
    ? (action as (prev: T) => T)(current)
    : action;
}

/** View mode shared by every article. */
export function useGlobalViewMode(): [
  UiViewMode,
  (action: SetStateAction<UiViewMode>) => void,
] {
  const [raw, setRaw] = useUiState(UI_VIEW_MODE_KEY, "original");
  const setMode = useCallback(
    (action: SetStateAction<UiViewMode>) => {
      const current = parseViewMode(readEffective(UI_VIEW_MODE_KEY, "original"));
      setRaw(parseViewMode(resolveAction(action, current)));
    },
    [setRaw],
  );
  return [parseViewMode(raw), setMode];
}

/** Font size shared by every article. */
export function useGlobalFontSize(): [
  number,
  (action: SetStateAction<number>) => void,
] {
  const [raw, setRaw] = useUiState(UI_FONT_SIZE_KEY, String(FONT_SIZE_DEFAULT));
  const setSize = useCallback(
    (action: SetStateAction<number>) => {
      const current = parseFontSize(
        readEffective(UI_FONT_SIZE_KEY, String(FONT_SIZE_DEFAULT)),
      );
      setRaw(String(clampFontSize(resolveAction(action, current))));
    },
    [setRaw],
  );
  return [parseFontSize(raw), setSize];
}

/** Subtitle-list visibility shared by every article. */
export function useGlobalShowFullSubtitles(): [
  boolean,
  (action: SetStateAction<boolean>) => void,
] {
  const [raw, setRaw] = useUiState(UI_SHOW_FULL_SUBTITLES_KEY, "false");
  const setFlag = useCallback(
    (action: SetStateAction<boolean>) => {
      const current = parseBoolean(
        readEffective(UI_SHOW_FULL_SUBTITLES_KEY, "false"),
        false,
      );
      setRaw(resolveAction(action, current) ? "true" : "false");
    },
    [setRaw],
  );
  return [parseBoolean(raw, false), setFlag];
}
