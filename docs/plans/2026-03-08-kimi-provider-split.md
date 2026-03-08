# Kimi Provider Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split Kimi into separate China and Global providers while keeping existing legacy `moonshot` configs working as China.

**Architecture:** Add two explicit provider ids in the frontend and backend, then centralize Moonshot endpoint resolution so chat, model sync, file upload, and subtitle extraction all derive URLs from provider identity. Treat legacy `moonshot` as an alias for China in shared predicates to avoid a migration.

**Tech Stack:** React, TypeScript, Tauri, Rust, Vitest, cargo test

---

### Task 1: Add frontend provider identities and labels

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/SettingsDialog.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/locales/zh.json`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/locales/en.json`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/locales/ja.json`

**Step 1: Write the failing test**

Add or extend a frontend test that renders provider labels or provider options and expects both `moonshot-cn` and `moonshot-global` to be present.

**Step 2: Run test to verify it fails**

Run: `pnpm vitest run textlingo-desktop/src/components/features/SettingsDialog*.test*`
Expected: FAIL because the new provider ids and labels do not exist yet.

**Step 3: Write minimal implementation**

- Add `moonshot-cn` and `moonshot-global` to `SUPPORTED_PROVIDERS`.
- Add duplicate preset model lists for both providers.
- Add localized provider labels for the new ids.
- Keep a label entry for legacy `moonshot` if the UI still needs to render saved configs cleanly.

**Step 4: Run test to verify it passes**

Run: `pnpm vitest run textlingo-desktop/src/components/features/SettingsDialog*.test*`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/SettingsDialog.tsx textlingo-desktop/src/locales/zh.json textlingo-desktop/src/locales/en.json textlingo-desktop/src/locales/ja.json
git commit -m "feat: add separate kimi provider identities"
```

### Task 2: Update frontend model sync and editing behavior

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/SettingsDialog.tsx`

**Step 1: Write the failing test**

Add or extend a test around model sync URL selection or provider editing logic that expects:

- `moonshot-cn` to use `https://api.moonshot.cn/v1/models`
- `moonshot-global` to use `https://api.moonshot.ai/v1/models`
- legacy `moonshot` configs to continue using China behavior

**Step 2: Run test to verify it fails**

Run: `pnpm vitest run textlingo-desktop/src/components/features/SettingsDialog*.test*`
Expected: FAIL because sync still hardcodes `api.moonshot.cn` for only `moonshot`.

**Step 3: Write minimal implementation**

- Update model sync provider checks to include both new providers.
- Resolve the correct models endpoint from provider id.
- Make editing legacy `moonshot` configs fall back to China preset models and UI behavior.
- Update any provider-specific conditionals that only recognize `moonshot`.

**Step 4: Run test to verify it passes**

Run: `pnpm vitest run textlingo-desktop/src/components/features/SettingsDialog*.test*`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/SettingsDialog.tsx
git commit -m "feat: route kimi model sync by region"
```

### Task 3: Add Rust Moonshot provider resolution helpers

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/ai_service.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/subtitle_extraction.rs`
- Test: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/tests/commands_test.rs`

**Step 1: Write the failing test**

Add Rust tests for helper behavior that expect:

- `moonshot-cn` chat URL resolves to `https://api.moonshot.cn/v1/chat/completions`
- `moonshot-global` chat URL resolves to `https://api.moonshot.ai/v1/chat/completions`
- legacy `moonshot` resolves to the China URL

**Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml moonshot`
Expected: FAIL because helper functions do not exist yet.

**Step 3: Write minimal implementation**

- Add shared Rust helpers for:
  - detecting Kimi providers
  - mapping provider id to Moonshot base URL
  - deriving `/chat/completions` and `/files` endpoints
- Replace direct string literals with helper calls where possible.

**Step 4: Run test to verify it passes**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml moonshot`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/ai_service.rs textlingo-desktop/src-tauri/src/subtitle_extraction.rs textlingo-desktop/src-tauri/tests/commands_test.rs
git commit -m "refactor: centralize kimi endpoint resolution"
```

### Task 4: Update backend chat and file upload behavior

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/ai_service.rs`

**Step 1: Write the failing test**

Add tests that cover Kimi-specific logic for both new providers:

- temperature override stays applied
- thinking mode is enabled for `k2.5`
- file upload accepts both regional providers and legacy `moonshot`

**Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml ai_service`
Expected: FAIL because Kimi-specific checks still only match `moonshot`.

**Step 3: Write minimal implementation**

- Replace `self.provider == "moonshot"` checks with a shared helper.
- Route file uploads to the correct `/files` endpoint for CN/Global.
- Keep legacy `moonshot` treated as China.

**Step 4: Run test to verify it passes**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml ai_service`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/ai_service.rs
git commit -m "feat: support kimi cn and global backend routing"
```

### Task 5: Update subtitle extraction and feature gating

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/subtitle_extraction.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/commands.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`

**Step 1: Write the failing test**

Add or extend tests that verify Kimi-specific subtitle/video gating still works for:

- `moonshot-cn`
- `moonshot-global`
- legacy `moonshot`

**Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml commands`
Run: `pnpm vitest run textlingo-desktop/src/components/features/ArticleReader*.test*`
Expected: FAIL because gating logic only matches `moonshot`.

**Step 3: Write minimal implementation**

- Update subtitle routing to use provider-specific Moonshot endpoints.
- Expand Kimi provider checks in command validation and article reader gating.
- Preserve legacy compatibility behavior.

**Step 4: Run test to verify it passes**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml commands`
Run: `pnpm vitest run textlingo-desktop/src/components/features/ArticleReader*.test*`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/subtitle_extraction.rs textlingo-desktop/src-tauri/src/commands.rs textlingo-desktop/src/components/features/ArticleReader.tsx
git commit -m "feat: preserve kimi feature gates across regions"
```

### Task 6: Verify there are no stale hardcoded Moonshot assumptions

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/OnboardingDialog.tsx`
- Modify: any remaining files found by search that still hardcode old provider behavior

**Step 1: Write the failing test**

If onboarding or other UI flows expose Kimi directly, add a focused test that expects the intended provider behavior to remain coherent after the split.

**Step 2: Run test to verify it fails**

Run the smallest relevant test command for the touched area.
Expected: FAIL only if that flow still assumes one provider id.

**Step 3: Write minimal implementation**

- Search for remaining `moonshot` provider checks.
- Convert intended active logic to support both new providers plus legacy alias.
- Leave truly legacy-only compatibility branches documented and minimal.

**Step 4: Run test to verify it passes**

Run the smallest relevant test command for the touched area.
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/OnboardingDialog.tsx
git commit -m "fix: clean up remaining kimi provider assumptions"
```

### Task 7: Final verification

**Files:**
- No code changes required unless verification exposes a defect

**Step 1: Run targeted frontend tests**

Run: `pnpm vitest run textlingo-desktop/src/components/features/SettingsDialog*.test* textlingo-desktop/src/components/features/ArticleReader*.test*`
Expected: PASS

**Step 2: Run targeted Rust tests**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml moonshot`
Expected: PASS

**Step 3: Run repository searches**

Run: `rg -n 'provider == "moonshot"|provider === "moonshot"|api\\.moonshot\\.cn' /Users/rqq/TextLingo/textlingo-desktop`
Expected: only intentional legacy alias handling and explicit China endpoint mapping remain.

**Step 4: Manual smoke-check guidance**

- Open settings and confirm both Kimi providers appear.
- Select each provider and confirm model sync hits the correct endpoint.
- Edit an existing legacy `moonshot` config and confirm it still loads as China.

**Step 5: Commit**

```bash
git status --short
```
