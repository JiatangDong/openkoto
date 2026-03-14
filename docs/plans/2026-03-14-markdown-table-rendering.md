# Markdown Table Rendering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable GFM table rendering for AI-generated chat and reply surfaces without changing article body rendering.

**Architecture:** Add a shared Markdown reply renderer that centralizes `react-markdown` configuration, including `remark-gfm` and consistent table styling. Wire only AI reply surfaces to the shared component so article body content in `ArticleReader` keeps its current behavior while analysis and explanation outputs gain table support.

**Tech Stack:** React 19, TypeScript, Vitest, Testing Library, `react-markdown`, `remark-gfm`

---

### Task 1: Capture the missing table behavior in tests

**Files:**
- Modify: `textlingo-desktop/src/components/features/AgentPanel.test.tsx`
- Create: `textlingo-desktop/src/components/ui/MarkdownContent.test.tsx`

**Step 1: Write the failing tests**

Add one integration test in `AgentPanel.test.tsx` that emits an assistant reply containing a Markdown table and expects a rendered `table` with header and cell text.

Add one renderer-focused test in `MarkdownContent.test.tsx` that renders a Markdown table directly and expects:
- a `table`
- header cells via `columnheader`
- body cells via `cell`

**Step 2: Run tests to verify they fail**

Run: `npm test -- src/components/features/AgentPanel.test.tsx src/components/ui/MarkdownContent.test.tsx`

Expected: FAIL because GFM tables are not parsed into table elements yet.

### Task 2: Implement the shared Markdown reply renderer

**Files:**
- Create: `textlingo-desktop/src/components/ui/MarkdownContent.tsx`
- Modify: `textlingo-desktop/package.json`

**Step 1: Write minimal implementation**

Create `MarkdownContent.tsx` that:
- wraps `ReactMarkdown`
- adds `remark-gfm`
- accepts `content`, `className`, and an optional `variant`
- defines shared renderers for paragraphs, lists, inline code, fenced code blocks, and GFM tables

Keep the API narrow. Do not add syntax highlighting or unrelated formatting features.

**Step 2: Add dependency**

Add `remark-gfm` to `textlingo-desktop/package.json` and refresh the npm lockfile.

**Step 3: Run tests to verify renderer passes**

Run: `npm test -- src/components/ui/MarkdownContent.test.tsx`

Expected: PASS

### Task 3: Wire the shared renderer into AI reply surfaces only

**Files:**
- Modify: `textlingo-desktop/src/components/features/AgentPanel.tsx`
- Modify: `textlingo-desktop/src/components/features/ArticleChatAssistant.tsx`
- Modify: `textlingo-desktop/src/components/features/ArticleExplanationPanel.tsx`
- Modify: `textlingo-desktop/src/components/features/ArticleReader.tsx`

**Step 1: Replace local `ReactMarkdown` usage**

Switch these AI reply surfaces to `MarkdownContent`:
- Agent assistant reply bubble
- Article chat assistant reply bubble
- Article explanation notes block
- Article analysis result block

Do not replace the article body renderer in `ArticleReader` for `content`.

**Step 2: Preserve existing layout expectations**

Keep surrounding container classes intact so spacing, colors, and overflow behavior remain stable. Only remove duplicated Markdown element mappings that the shared component now owns.

**Step 3: Run focused tests**

Run: `npm test -- src/components/features/AgentPanel.test.tsx src/components/ui/MarkdownContent.test.tsx`

Expected: PASS

### Task 4: Verify the scoped fix

**Files:**
- No code changes expected

**Step 1: Run targeted verification**

Run: `npm test -- src/components/features/AgentPanel.test.tsx src/components/ui/MarkdownContent.test.tsx`

Expected: PASS with the new table coverage green.

**Step 2: Run typecheck if dependency and component wiring changed types**

Run: `npm run typecheck`

Expected: PASS
