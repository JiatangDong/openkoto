# Book Assistant Sidebar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reuse one assistant sidebar shell for article and book readers, and add mind map support to PDF/EPUB/TXT book reading.

**Architecture:** Extract the reader-level assistant layout into a shared shell component, migrate `ArticleReader` onto it without behavior loss, then migrate `BookReader` onto the same shell and add `Mind Map` + `Chat` tabs. Keep the existing mind map task/artifact flow unchanged.

**Tech Stack:** React, TypeScript, Vitest, Testing Library, Tailwind, Tauri invoke

---

### Task 1: Add a shared assistant sidebar shell

**Files:**
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.test.tsx`

**Step 1: Write the failing test**

Cover:
- renders layout mode buttons
- renders tabs
- toggles `compact / wide / full`
- hides main pane in `full`

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/AssistantSidebarShell.test.tsx`

**Step 3: Write minimal implementation**

Implement:
- shared shell props
- internal `activeTab`
- layout mode persistence with `storageKey`
- `mainPaneClass` / `assistantPaneClass`

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/AssistantSidebarShell.test.tsx`

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.test.tsx
git commit -m "feat: add shared assistant sidebar shell"
```

### Task 2: Migrate article reader onto the shared shell

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`

**Step 1: Write the failing test**

Add article-reader regression assertions for:
- `讲解 / 思维导图 / 对话`
- layout mode switching
- assistant pane data attributes

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`

**Step 3: Write minimal implementation**

Replace reader-local sidebar layout with `AssistantSidebarShell`, preserving:
- current tabs
- current layout storage behavior
- current show/hide behavior

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx
git commit -m "refactor: move article reader to shared assistant shell"
```

### Task 3: Add book reader mind map support through the shared shell

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.tsx`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.test.tsx`

**Step 1: Write the failing test**

Cover:
- renders `思维导图` and `对话` tabs for books
- defaults to `思维导图`
- renders `ArticleMindMapPanel` for books
- renders `ArticleChatAssistant` on chat tab
- supports `1/3 / 2/3 / 全屏`

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/BookReader.test.tsx`

**Step 3: Write minimal implementation**

Update `BookReader` to:
- use `AssistantSidebarShell`
- pass left-side book reader content as main content
- mount `ArticleMindMapPanel`
- keep selected-text driven `ArticleChatAssistant`

**Step 4: Run test to verify it passes**

Run: `npm test -- src/components/features/BookReader.test.tsx`

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.test.tsx
git commit -m "feat: add mind map assistant to book reader"
```

### Task 4: Verify integrated behavior and clean up

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx`

**Step 1: Run focused test suites**

Run:
- `npm test -- src/components/features/AssistantSidebarShell.test.tsx`
- `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
- `npm test -- src/components/features/BookReader.test.tsx`

**Step 2: Run static verification**

Run:
- `npm run typecheck`
- `npm run build`

**Step 3: Fix any integration regressions**

Keep changes minimal and scoped to:
- layout classes
- tab state wiring
- shell prop contracts

**Step 4: Re-run verification**

Run:
- `npm test -- src/components/features/AssistantSidebarShell.test.tsx`
- `npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
- `npm test -- src/components/features/BookReader.test.tsx`
- `npm run typecheck`
- `npm run build`

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.tsx /Users/rqq/TextLingo/textlingo-desktop/src/components/features/*.test.tsx
git commit -m "refactor: unify reader assistant sidebars"
```
