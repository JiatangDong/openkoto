# Material Dialog Theme Unification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the new material dialog use theme-primary styling for active navigation items and the book import panel so the California theme remains readable and coherent.

**Architecture:** Keep the existing dialog/component structure intact and replace hard-coded accent utility classes with shared theme-token-based classes. Lock the behavior with focused component tests that assert the selected-tab styling and book-import hint styling no longer rely on hard-coded category colors.

**Tech Stack:** React 19, TypeScript, Tailwind CSS v4 utility classes, Vitest, Testing Library

---

### Task 1: Add failing tests for theme-token styling

**Files:**
- Create: `textlingo-desktop/src/components/features/NewMaterialDialog.test.tsx`
- Modify: `textlingo-desktop/src/components/features/BookImportForm.tsx` (later)
- Modify: `textlingo-desktop/src/components/features/NewMaterialDialog.tsx` (later)

**Step 1: Write the failing test**

Create tests that:
- render `NewMaterialDialog` in open state,
- click each material type tab,
- assert the active tab uses `bg-primary/10 text-primary`,
- assert legacy hard-coded active color classes are absent,
- render `BookImportForm`,
- assert the hint container uses primary token classes instead of purple classes.

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/NewMaterialDialog.test.tsx`
Expected: FAIL because active tabs and book hint still use hard-coded color classes.

**Step 3: Write minimal implementation**

Replace hard-coded active tab classes in `NewMaterialDialog.tsx` with a shared primary-based active state helper and update `BookImportForm.tsx` hint/icon styling to theme-token classes.

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/NewMaterialDialog.test.tsx`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/NewMaterialDialog.test.tsx textlingo-desktop/src/components/features/NewMaterialDialog.tsx textlingo-desktop/src/components/features/BookImportForm.tsx docs/plans/2026-03-06-material-dialog-theme-unification-design.md docs/plans/2026-03-06-material-dialog-theme-unification.md
git commit -m "fix: unify material dialog theme colors"
```

### Task 2: Run broader verification

**Files:**
- Test: `textlingo-desktop/src/components/features/NewMaterialDialog.test.tsx`
- Test: existing desktop typecheck/test targets

**Step 1: Run focused test suite**

Run: `npm test -- src/components/features/NewMaterialDialog.test.tsx`
Expected: PASS

**Step 2: Run broader verification**

Run: `npm test -- src/components/features/SelectPackDialog.test.tsx src/components/features/WordRecitePanel.test.tsx`
Expected: PASS

**Step 3: Run typecheck**

Run: `npm run typecheck`
Expected: PASS

**Step 4: Commit if needed**

```bash
git status --short
```

Review staged changes before any commit.
