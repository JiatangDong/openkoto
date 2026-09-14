import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { invoke } from "@tauri-apps/api/core";
import {
  resetUiStateForTests,
  UI_FONT_SIZE_KEY,
  UI_SHOW_FULL_SUBTITLES_KEY,
  UI_VIEW_MODE_KEY,
  useGlobalFontSize,
  useGlobalShowFullSubtitles,
  useGlobalViewMode,
  useScopedShowFullSubtitles,
  useScopedUiState,
  useScopedViewMode,
} from "./uiState";

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(),
}));

const invokeMock = vi.mocked(invoke);

/** In-memory fake backend honoring get/set_ui_state merge semantics. */
let fakeBackend: Record<string, string> = {};

function mockBackend(initial: Record<string, string> = {}) {
  fakeBackend = { ...initial };
  invokeMock.mockImplementation(
    ((cmd: string, args?: { updates?: Record<string, string | null> }) => {
      if (cmd === "get_ui_state") return Promise.resolve({ ...fakeBackend });
      if (cmd === "set_ui_state") {
        const updates = (args?.updates ?? {}) as Record<string, string | null>;
        for (const [key, value] of Object.entries(updates)) {
          if (value === null || value === undefined) delete fakeBackend[key];
          else fakeBackend[key] = value;
        }
        return Promise.resolve({ ...fakeBackend });
      }
      return Promise.reject(new Error(`unexpected command: ${cmd}`));
    }) as typeof invoke,
  );
}

function setUiStateCalls(): Record<string, string | null>[] {
  return invokeMock.mock.calls
    .filter(([cmd]) => cmd === "set_ui_state")
    .map(([, args]) => (args as { updates: Record<string, string | null> }).updates);
}

async function flushPromises() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("uiState", () => {
  beforeEach(() => {
    resetUiStateForTests();
    invokeMock.mockReset();
    mockBackend();
    window.localStorage.clear();
  });

  it("falls back to the default when nothing is stored", () => {
    const { result } = renderHook(() => useScopedUiState(UI_VIEW_MODE_KEY, "a1", "original"));
    expect(result.current[0]).toBe("original");
  });

  it("global settings are identical in every article and write one key", async () => {
    const { result, unmount } = renderHook(() => useGlobalViewMode());
    act(() => {
      result.current[1]("bilingual");
    });
    await flushPromises();
    unmount();

    // A different article sees the same value with no per-article key.
    const { result: next } = renderHook(() => useGlobalViewMode());
    expect(next.current[0]).toBe("bilingual");

    const calls = setUiStateCalls();
    expect(calls.length).toBeGreaterThan(0);
    const last = calls[calls.length - 1];
    expect(last).toEqual({ [UI_VIEW_MODE_KEY]: "bilingual" });
    expect(fakeBackend).toEqual({ [UI_VIEW_MODE_KEY]: "bilingual" });
  });

  it("a never-before-seen article inherits the last-used global setting", async () => {
    const { result, unmount } = renderHook(() => useScopedViewMode("article-a"));
    act(() => {
      result.current[1]("bilingual");
    });
    await flushPromises();
    unmount();

    const { result: next } = renderHook(() => useScopedViewMode("article-b"));
    expect(next.current[0]).toBe("bilingual");
  });

  it("persists scoped and global keys to the backend immediately", async () => {
    const { result } = renderHook(() => useScopedShowFullSubtitles("article-a"));
    act(() => {
      result.current[1](true);
    });
    await flushPromises();

    const calls = setUiStateCalls();
    expect(calls.length).toBeGreaterThan(0);
    const last = calls[calls.length - 1];
    expect(last[`${UI_SHOW_FULL_SUBTITLES_KEY}_article-a`]).toBe("true");
    expect(last[UI_SHOW_FULL_SUBTITLES_KEY]).toBe("true");
  });

  it("hydration never overwrites a setting changed while the request was in flight", async () => {
    let resolveHydrate!: (value: Record<string, string>) => void;
    invokeMock.mockImplementation(
      ((cmd: string, args?: { updates?: Record<string, string | null> }) => {
        if (cmd === "get_ui_state") {
          return new Promise<Record<string, string>>((resolve) => {
            resolveHydrate = resolve;
          });
        }
        if (cmd === "set_ui_state") {
          const updates = (args?.updates ?? {}) as Record<string, string>;
          Object.assign(fakeBackend, updates);
          return Promise.resolve({ ...fakeBackend });
        }
        return Promise.reject(new Error(`unexpected command: ${cmd}`));
      }) as typeof invoke,
    );

    const { result } = renderHook(() => useScopedViewMode("article-a"));

    // User acts before the stale backend snapshot arrives.
    act(() => {
      result.current[1]("bilingual");
    });
    await act(async () => {
      resolveHydrate({ [UI_VIEW_MODE_KEY]: "original" });
    });
    await flushPromises();

    expect(result.current[0]).toBe("bilingual");
    expect(fakeBackend[UI_VIEW_MODE_KEY]).toBe("bilingual");
  });

  it("persists font size with clamping", async () => {
    const { result } = renderHook(() => useGlobalFontSize());
    expect(result.current[0]).toBe(18);

    act(() => {
      result.current[1](24);
    });
    await flushPromises();
    expect(result.current[0]).toBe(24);

    const calls = setUiStateCalls();
    const last = calls[calls.length - 1];
    expect(last).toEqual({ [UI_FONT_SIZE_KEY]: "24" });

    act(() => {
      result.current[1](999);
    });
    expect(result.current[0]).toBe(32);
  });

  it("writes subtitle visibility as one global key", async () => {
    const { result } = renderHook(() => useGlobalShowFullSubtitles());
    act(() => {
      result.current[1](true);
    });
    await flushPromises();

    expect(result.current[0]).toBe(true);
    expect(fakeBackend).toEqual({ [UI_SHOW_FULL_SUBTITLES_KEY]: "true" });
  });

  it("migrates legacy localStorage keys into the backend and clears them", async () => {
    window.localStorage.setItem("article-reader-view-mode", "bilingual");

    const { result } = renderHook(() => useGlobalViewMode());
    await flushPromises();
    await flushPromises();

    expect(result.current[0]).toBe("bilingual");
    expect(fakeBackend[UI_VIEW_MODE_KEY]).toBe("bilingual");
    expect(window.localStorage.getItem("article-reader-view-mode")).toBeNull();
  });

  it.each([["legacy-first"], ["canonical-first"]])(
    "canonical global beats the legacy alias regardless of insertion order (%s)",
    async (order) => {
      // Stale legacy value vs newer canonical value for the same setting.
      const seed: [string, string][] =
        order === "legacy-first"
          ? [
              ["article-reader-view-mode", "original"],
              [UI_VIEW_MODE_KEY, "bilingual"],
            ]
          : [
              [UI_VIEW_MODE_KEY, "bilingual"],
              ["article-reader-view-mode", "original"],
            ];
      for (const [key, value] of seed) {
        window.localStorage.setItem(key, value);
      }

      const { result } = renderHook(() => useGlobalViewMode());
      await flushPromises();
      await flushPromises();

      expect(result.current[0]).toBe("bilingual");
      expect(fakeBackend[UI_VIEW_MODE_KEY]).toBe("bilingual");
      // Losing alias is still cleaned up once its (losing) value is confirmed.
      expect(window.localStorage.getItem("article-reader-view-mode")).toBeNull();
    },
  );

  it("drops stale per-article leftovers instead of resurrecting them", async () => {
    // Adjacent entries: removing entries during iteration used to shift
    // indices and silently skip neighbours — the snapshot pass fixes that.
    window.localStorage.setItem("article-reader-view-mode", "bilingual");
    window.localStorage.setItem("textlingo_font_size_article-a", "24");
    window.localStorage.setItem(`${UI_VIEW_MODE_KEY}_article-a`, "original");

    renderHook(() => useGlobalViewMode());
    await flushPromises();
    await flushPromises();

    // Legacy global migrates; scoped leftovers never reach the backend…
    expect(fakeBackend[UI_VIEW_MODE_KEY]).toBe("bilingual");
    expect(fakeBackend[`${UI_FONT_SIZE_KEY}_article-a`]).toBeUndefined();
    expect(fakeBackend[`${UI_VIEW_MODE_KEY}_article-a`]).toBeUndefined();
    // …and are dropped from the read cache.
    expect(window.localStorage.getItem(`${UI_VIEW_MODE_KEY}_article-a`)).toBeNull();
    expect(window.localStorage.getItem("textlingo_font_size_article-a")).toBeNull();
  });

  it("promotes a scoped leftover when the global is missing everywhere", async () => {
    window.localStorage.setItem(`${UI_FONT_SIZE_KEY}_article-a`, "24");

    const { result } = renderHook(() => useGlobalFontSize());
    await flushPromises();
    await flushPromises();

    expect(result.current[0]).toBe(24);
    expect(fakeBackend[UI_FONT_SIZE_KEY]).toBe("24");
  });

  it("deletes stale per-article backend keys on hydrate", async () => {
    mockBackend({
      [UI_VIEW_MODE_KEY]: "bilingual",
      [`${UI_VIEW_MODE_KEY}_article-a`]: "original",
      [`${UI_SHOW_FULL_SUBTITLES_KEY}_article-a`]: "true",
    });

    renderHook(() => useGlobalViewMode());
    await flushPromises();
    await flushPromises();

    // Globals survive; scoped keys are queued as deletions.
    expect(fakeBackend[UI_VIEW_MODE_KEY]).toBe("bilingual");
    expect(fakeBackend[`${UI_VIEW_MODE_KEY}_article-a`]).toBeUndefined();
    expect(fakeBackend[`${UI_SHOW_FULL_SUBTITLES_KEY}_article-a`]).toBeUndefined();
    const deletes = setUiStateCalls().flatMap((updates) =>
      Object.entries(updates)
        .filter(([, value]) => value === null)
        .map(([key]) => key),
    );
    expect(deletes).toContain(`${UI_VIEW_MODE_KEY}_article-a`);
    expect(deletes).toContain(`${UI_SHOW_FULL_SUBTITLES_KEY}_article-a`);
  });

  it("keeps legacy data until the backend confirms the migrated write", async () => {
    window.localStorage.setItem("article-reader-view-mode", "bilingual");
    invokeMock.mockImplementation((cmd: string) => {
      if (cmd === "get_ui_state") return Promise.resolve({});
      return Promise.reject(new Error("backend down"));
    });

    renderHook(() => useScopedViewMode("article-a"));
    await flushPromises();

    // Migration queued but unconfirmed: the value is visible via cache…
    expect(window.localStorage.getItem(UI_VIEW_MODE_KEY)).toBe("bilingual");
    // …but the legacy entry is retained until persistence succeeds.
    expect(window.localStorage.getItem("article-reader-view-mode")).toBe("bilingual");
  });

  it("restores from the backend even when localStorage throws", async () => {
    mockBackend({ [UI_VIEW_MODE_KEY]: "bilingual" });
    const getItem = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("denied", "SecurityError");
    });
    const setItem = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("denied", "SecurityError");
    });
    try {
      const { result } = renderHook(() => useScopedViewMode("article-a"));
      await flushPromises();
      await flushPromises();
      expect(result.current[0]).toBe("bilingual");
    } finally {
      getItem.mockRestore();
      setItem.mockRestore();
    }
  });

  it("gives up retrying after bounded attempts instead of spinning forever", async () => {
    vi.useFakeTimers();
    try {
      invokeMock.mockImplementation((cmd: string) => {
        if (cmd === "get_ui_state") return Promise.resolve({});
        return Promise.reject(new Error("backend down"));
      });
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { result } = renderHook(() => useScopedViewMode("article-a"));
      act(() => {
        result.current[1]("bilingual");
      });
      // Flush the first persist attempt so its retry timer is scheduled
      // before advancing the clock.
      await act(async () => {});
      // Initial attempt + 3 bounded retries (1s, 2s, 4s), then silence.
      await act(async () => {
        await vi.advanceTimersByTimeAsync(60_000);
      });

      const setCalls = invokeMock.mock.calls.filter(([cmd]) => cmd === "set_ui_state");
      expect(setCalls.length).toBe(1 + 3);
      expect(errorSpy).toHaveBeenCalled();
      // Value is still visible locally despite the outage.
      expect(result.current[0]).toBe("bilingual");
      errorSpy.mockRestore();
    } finally {
      vi.useRealTimers();
    }
  });
});
