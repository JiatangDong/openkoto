# All Words Pack Export Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let the `全部单词` menu export a synthetic OpenKoto pack containing every favorited vocabulary entry.

**Architecture:** Keep the existing favorites UI flow and reuse `handleExportWordPack("all")` from the left-side menu. Extend the Rust `export_word_pack_cmd` so `pack_id == "all"` builds pack metadata in memory and exports every favorite vocabulary without relying on a persisted `WordPack`.

**Tech Stack:** React 19, TypeScript, Vitest, Tauri, Rust

---

### Task 1: Add failing tests for all-words export

**Files:**
- Modify: `textlingo-desktop/src/components/features/FavoritesPage.test.tsx`

**Step 1: Write the failing test**

Add a test that opens the `全部单词` row menu, clicks `导出单词包`, and expects:
- `invoke("export_word_pack_cmd", { packId: "all" })`
- a save dialog default path based on `全部单词`

**Step 2: Run test to verify it fails**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: FAIL until the export flow accepts `all`

**Step 3: Write minimal implementation**

No implementation in this task.

**Step 4: Re-run targeted test**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: FAIL remains for the intended reason

### Task 2: Implement synthetic pack export

**Files:**
- Modify: `textlingo-desktop/src/components/features/FavoritesPage.tsx`
- Modify: `textlingo-desktop/src-tauri/src/commands.rs`

**Step 1: Write minimal implementation**

Update the frontend export handler so `all` proceeds instead of alerting.

Update Rust so `export_word_pack_cmd`:
- detects `pack_id == "all"`
- loads all favorite vocabularies
- builds synthetic pack metadata named `全部单词`
- serializes the same export schema used by real packs

**Step 2: Run targeted tests**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: PASS

**Step 3: Run Rust verification if possible**

Run a targeted cargo test or project check for the Tauri crate if available.

### Task 3: Full verification

**Files:**
- Verify only

**Step 1: Run focused frontend tests**

Run: `npm test -- FavoritesPage.test.tsx WordRecitePanel.test.tsx`
Expected: PASS

**Step 2: Run typecheck**

Run: `npm run typecheck`
Expected: PASS
