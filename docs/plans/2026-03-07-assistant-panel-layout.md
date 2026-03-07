# Assistant Panel Layout Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add fixed `1/3`, `2/3`, and `full` layout modes for the right assistant panel and make the mind map UI adapt gracefully in narrow mode.

**Architecture:** Store assistant panel mode in the article reader, render mode controls beside the right-side tabs, and pass the active mode into the mind map panel. Adjust the mind map panel layout based on mode so compact mode prioritizes the canvas while wide/full modes progressively reveal supporting UI.

**Tech Stack:** React 19, TypeScript, Tailwind CSS, Vitest, Testing Library, Mind Elixir

---

### Task 1: Define Reader-Level Panel Mode

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`

**Step 1: Write the failing test**

Add a reader test that expects layout controls `1/3`, `2/3`, and `全屏` to appear in the right sidebar header when the assistant panel is visible.

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because the layout controls do not exist yet.

**Step 3: Write minimal implementation**

In [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx):

- Add `assistantPanelMode` state with values `compact | wide | full`
- Render a segmented control in the assistant header
- Default to `compact`

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS for the new layout-control assertion.

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "feat: add assistant panel mode controls"
```

### Task 2: Apply Reader Container Width Modes

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`

**Step 1: Write the failing test**

Add a test that switches from `1/3` to `2/3` to `全屏` and asserts:

- the right panel container class changes
- the left reading pane hides in `full`

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because mode changes do not affect layout yet.

**Step 3: Write minimal implementation**

In [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx):

- Compute container classes from `assistantPanelMode`
- Hide the left reader section when mode is `full`
- Expand the right sidebar width for `wide` and `full`

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS for mode switching behavior.

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "feat: apply assistant panel width modes"
```

### Task 3: Pass Mode Into Mind Map Panel

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx`

**Step 1: Write the failing test**

Add a panel test that renders the mind map panel in `compact`, `wide`, and `full` modes and asserts mode-specific wrappers or data attributes exist.

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because the panel does not accept a mode prop yet.

**Step 3: Write minimal implementation**

In [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx):

- Add a `panelMode` prop
- Add mode-specific root classes or `data-panel-mode`
- Update [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx) to pass the current mode

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS for the new mode-prop behavior.

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "feat: thread assistant panel mode into mind map panel"
```

### Task 4: Make Compact Mode Less Crowded

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`

**Step 1: Write the failing test**

Add a test that expects `compact` mode to:

- collapse or hide node details by default
- collapse or hide the log panel by default
- use a tighter stats layout than `wide`

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because compact mode still renders the full stacked layout.

**Step 3: Write minimal implementation**

In [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx):

- Add compact-mode booleans
- Collapse the details section behind a small toggle
- Collapse the log panel behind a small toggle
- Reduce header and stats density

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS for compact-mode behavior.

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "feat: optimize compact mind map layout"
```

### Task 5: Expand Wide and Full Canvas Space

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`

**Step 1: Write the failing test**

Add a test asserting:

- `wide` mode uses a larger canvas class than `compact`
- `full` mode uses the largest canvas class

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because canvas size is currently fixed.

**Step 3: Write minimal implementation**

In [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx):

- Compute canvas height/spacing by mode
- Reduce non-canvas chrome in `wide`
- Maximize canvas in `full`

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS for canvas sizing behavior.

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "feat: enlarge mind map canvas in wide and full modes"
```

### Task 6: Persist Mode Preference

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`

**Step 1: Write the failing test**

Add a test that simulates choosing `全屏` and expects the mode to be restored from local storage on remount.

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because mode is not persisted yet.

**Step 3: Write minimal implementation**

In [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx):

- Read initial mode from `localStorage`
- Validate against supported enum values
- Save on change

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS for persistence behavior.

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "feat: persist assistant panel layout mode"
```

### Task 7: Final Verification

**Files:**
- Verify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Verify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx`
- Verify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`

**Step 1: Run targeted tests**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS

**Step 2: Run typecheck**

Run: `npm run typecheck`
Expected: PASS

**Step 3: Run production build**

Run: `npm run build`
Expected: PASS

**Step 4: Manual verification**

Run the app and verify:

- `1/3` mode is compact but usable
- `2/3` visibly expands the assistant panel
- `全屏` hides the reader and maximizes the assistant
- Mind map is less crowded in `1/3`
- Mind map gets larger in `2/3` and `全屏`

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx /Users/rqq/TextLingo/docs/plans/2026-03-07-assistant-panel-layout-design.md /Users/rqq/TextLingo/docs/plans/2026-03-07-assistant-panel-layout.md
git commit -m "feat: add assistant panel layout modes"
```
