# Onboarding Local AI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Ollama and LM Studio setup to the first-run onboarding flow without changing the Settings dialog.

**Architecture:** Extend onboarding step 2 with a third top-level provider mode for local AI, add nested provider cards for Ollama and LM Studio, and persist the chosen local provider through the existing `save_model_config` and `set_active_model_config` commands. Reuse the app's current provider schema instead of introducing onboarding-only storage.

**Tech Stack:** React 19, TypeScript, Tauri 2, Vitest, Testing Library

---

### Task 1: Add onboarding test coverage for local AI save flow

**Files:**
- Create: `textlingo-desktop/src/components/features/OnboardingDialog.test.tsx`

**Step 1: Write the failing test**

Add a focused component test that:
- opens onboarding step 2,
- selects the new local AI path,
- chooses Ollama,
- fills a model name,
- completes onboarding,
- asserts `save_config_cmd`, `save_model_config`, and `set_active_model_config` are invoked with the expected local-provider payload.

**Step 2: Run test to verify it fails**

Run: `npm test -- src/components/features/OnboardingDialog.test.tsx`
Expected: FAIL because onboarding has no local-AI branch yet.

**Step 3: Write minimal implementation**

No implementation in this task.

**Step 4: Run test to verify it still fails for the right reason**

Run: `npm test -- src/components/features/OnboardingDialog.test.tsx`
Expected: FAIL on missing local-AI UI or missing payload fields.

### Task 2: Implement local AI onboarding UI and save path

**Files:**
- Modify: `textlingo-desktop/src/components/features/OnboardingDialog.tsx`
- Modify: `textlingo-desktop/src/locales/zh.json`
- Modify: `textlingo-desktop/src/locales/en.json`
- Modify: `textlingo-desktop/src/locales/ja.json`

**Step 1: Implement the smallest passing UI**

Add:
- a third top-level onboarding option for `Local AI`,
- nested cards for `Ollama` and `LM Studio`,
- local base URL input,
- Ollama model sync plus manual fallback,
- LM Studio manual model input,
- save logic that creates a local `model_config` without requiring an API key.

**Step 2: Run the test to verify it passes**

Run: `npm test -- src/components/features/OnboardingDialog.test.tsx`
Expected: PASS

**Step 3: Refine the UX without changing behavior**

Polish spacing, copy, and card visuals so the local path feels consistent with the existing onboarding design.

### Task 3: Run focused verification

**Files:**
- Test: `textlingo-desktop/src/components/features/OnboardingDialog.test.tsx`
- Test: `textlingo-desktop/src/App.test.tsx`
- Test: `textlingo-desktop/src/components/features/SettingsDialog.test.tsx`

**Step 1: Run onboarding and app tests**

Run: `npm test -- src/components/features/OnboardingDialog.test.tsx src/App.test.tsx src/components/features/SettingsDialog.test.tsx`
Expected: PASS

**Step 2: Run typecheck**

Run: `npm run typecheck`
Expected: PASS

**Step 3: Review the working tree**

Run: `git status --short`
Expected: only intended onboarding, locale, test, and plan file changes remain.
