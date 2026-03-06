# Favorites Pack Actions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move favorites management actions into the left-side pack list, while turning the top-right management control into a dedicated import-word-pack button.

**Architecture:** Keep `FavoritesPage` as the orchestration layer for data loading and action handlers. Move per-pack action presentation into `WordPackManager`, with separate menus for `all`, system packs, and normal packs so each row exposes only valid actions.

**Tech Stack:** React 19, TypeScript, Vitest, Testing Library, Radix UI dropdown menu, Tauri invoke APIs

---

### Task 1: Add failing tests for the new action layout

**Files:**
- Modify: `textlingo-desktop/src/components/features/FavoritesPage.test.tsx`

**Step 1: Write the failing test**

Add tests that verify:
- the top-right button shows `导入单词包` instead of `管理`
- the `全部单词` row has a menu containing only list-export actions
- a normal pack row has a menu containing list-export, pack-export, and delete actions

**Step 2: Run test to verify it fails**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: FAIL because the current UI still renders the old top-right `管理` dropdown and no row-level menu for `全部单词`

**Step 3: Write minimal implementation**

No implementation in this task.

**Step 4: Re-run targeted test**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: FAIL remains, confirming the tests are asserting the intended behavior

**Step 5: Commit**

Skip commit for now; commit after implementation passes.

### Task 2: Move management actions into the pack list

**Files:**
- Modify: `textlingo-desktop/src/components/features/FavoritesPage.tsx`
- Modify: `textlingo-desktop/src/components/features/WordPackManager.tsx`

**Step 1: Write the minimal implementation**

Update `FavoritesPage` to:
- replace the top-right management dropdown with a single `导入单词包` button wired to the existing hidden file input
- pass row-level action callbacks into `WordPackManager`

Update `WordPackManager` to:
- add `...` dropdown triggers for `全部单词` and each pack row
- route export-list actions through the current selection target
- hide delete for system packs
- stop menu clicks from changing selection accidentally

**Step 2: Run targeted tests**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: PASS

**Step 3: Refactor if needed**

Keep action wiring DRY by extracting a small row-menu renderer or row action config if duplication becomes noisy.

**Step 4: Re-run targeted tests**

Run: `npm test -- FavoritesPage.test.tsx`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/FavoritesPage.tsx textlingo-desktop/src/components/features/WordPackManager.tsx textlingo-desktop/src/components/features/FavoritesPage.test.tsx
git commit -m "feat: move favorites pack actions into list"
```

### Task 3: Verify no regression in related favorites behavior

**Files:**
- Verify only

**Step 1: Run focused verification**

Run: `npm test -- FavoritesPage.test.tsx WordRecitePanel.test.tsx`
Expected: PASS

**Step 2: Run typecheck for the desktop app**

Run: `npm run typecheck`
Expected: PASS

**Step 3: Commit if verification is clean**

If not already committed in Task 2, commit the tested change set.
