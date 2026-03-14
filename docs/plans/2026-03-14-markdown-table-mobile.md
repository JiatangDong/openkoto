# Markdown Table Mobile Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve narrow-screen behavior for AI-generated Markdown tables without changing their semantic table structure.

**Architecture:** Adjust the shared `MarkdownContent` renderer so all AI reply surfaces inherit the same mobile-friendly table wrapper, width strategy, and cell wrapping behavior. Keep the change scoped to shared Markdown table rendering and verify it through renderer-level tests.

**Tech Stack:** React 19, TypeScript, Vitest, Testing Library, `react-markdown`, Tailwind CSS

---

### Task 1: Capture the narrow-screen table requirements in tests

**Files:**
- Modify: `textlingo-desktop/src/components/ui/MarkdownContent.test.tsx`

**Step 1: Write the failing test**

Extend the existing table test to assert:
- the wrapper around the table has horizontal scrolling classes suitable for touch devices
- the table uses content-driven width instead of only `min-w-full`
- cells include wrapping classes for narrow screens

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/ui/MarkdownContent.test.tsx`

Expected: FAIL because the current shared renderer does not include those classes.

### Task 2: Implement the shared renderer update

**Files:**
- Modify: `textlingo-desktop/src/components/ui/MarkdownContent.tsx`

**Step 1: Write minimal implementation**

Update the table wrapper and table element classes to:
- improve touch scrolling
- isolate horizontal overscroll
- let the table be at least container width but expand to content width when needed

Update `th` and `td` classes so narrow screens wrap long values instead of forcing unnecessary overflow.

**Step 2: Run test to verify it passes**

Run: `npm test -- src/components/ui/MarkdownContent.test.tsx`

Expected: PASS

### Task 3: Verify no regressions in the existing reply surfaces

**Files:**
- No code changes expected

**Step 1: Run focused regression checks**

Run: `npm test -- src/components/ui/MarkdownContent.test.tsx src/components/features/AgentPanel.test.tsx`

Expected: PASS

**Step 2: Run typecheck**

Run: `npm run typecheck`

Expected: PASS
