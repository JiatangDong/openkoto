# OpenCode Agent Runtime Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the embedded Claude-based agent runtime with an OpenCode-based runtime that reuses the app's existing model settings, task storage, article tools, and artifact contracts.

**Architecture:** Keep React and Rust/Tauri as the product shell and source-of-truth data layer, but replace the Node worker internals with an OpenCode-based runtime that resolves the active provider from existing model configs, runs recipe-driven tasks, and emits normalized task events. Preserve the current article tool semantics and `MindMapResult` artifact contract so the UI and storage layers stay stable.

**Tech Stack:** Tauri v2, Rust, React 19, TypeScript, Node.js, OpenCode, Zod/JSON Schema, Vitest, Rust tests

---

### Task 1: Record the runtime-neutral worker protocol

**Files:**
- Create: `textlingo-desktop/agent-worker/src/protocol.ts`
- Test: `textlingo-desktop/agent-worker/src/protocol.test.ts`

**Step 1: Write the failing test**

Add tests for:
- parsing `agent.run` requests,
- validating the event envelope types,
- rejecting invalid `task.error` payloads without error codes.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/protocol.test.ts`
Expected: FAIL because the protocol definitions do not exist yet.

**Step 3: Write minimal implementation**

Define protocol types and validators for:
- `agent.run`
- `worker.ready`
- `worker.heartbeat`
- `task.started`
- `task.progress`
- `task.log`
- `task.result`
- `task.error`

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/protocol.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/src/protocol.ts textlingo-desktop/agent-worker/src/protocol.test.ts
git commit -m "refactor: define opencode worker protocol"
```

### Task 2: Add provider normalization for existing model configs

**Files:**
- Create: `textlingo-desktop/agent-worker/src/provider/resolveProvider.ts`
- Test: `textlingo-desktop/agent-worker/src/provider/resolveProvider.test.ts`
- Modify: `textlingo-desktop/src-tauri/src/types.rs`
- Modify: `textlingo-desktop/src/types/index.ts`

**Step 1: Write the failing test**

Add tests covering:
- `google` -> `native_google`
- `anthropic` -> `native_anthropic`
- `openai` / `openrouter` / `openai-compatible` -> `openai_compatible`
- `ollama` / `lmstudio` experimental mapping
- unsupported provider resolution with reason strings

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/provider/resolveProvider.test.ts`
Expected: FAIL because the resolver does not exist yet.

**Step 3: Write minimal implementation**

Add normalized provider types and a resolver that consumes the active model config shape:
- `api_provider`
- `api_key`
- `model`
- `base_url`

Keep the user-facing config model unchanged.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/provider/resolveProvider.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/src/provider/resolveProvider.ts textlingo-desktop/agent-worker/src/provider/resolveProvider.test.ts textlingo-desktop/src-tauri/src/types.rs textlingo-desktop/src/types/index.ts
git commit -m "feat: normalize model configs for opencode runtime"
```

### Task 3: Replace the worker runtime shell

**Files:**
- Modify: `textlingo-desktop/agent-worker/package.json`
- Modify: `textlingo-desktop/agent-worker/src/index.ts`
- Create: `textlingo-desktop/agent-worker/src/runtime.ts`
- Test: `textlingo-desktop/agent-worker/src/runtime.test.ts`

**Step 1: Write the failing test**

Add tests for:
- emitting `worker.ready` on startup,
- routing `agent.run` requests into task execution,
- emitting `task.error` with normalized codes when provider resolution fails.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.test.ts`
Expected: FAIL because the new runtime shell is not implemented.

**Step 3: Write minimal implementation**

Replace the current Claude-specific worker runtime shell with:
- startup ready event emission,
- heartbeat emission,
- request parsing,
- provider resolution,
- recipe dispatch,
- normalized error event emission.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/package.json textlingo-desktop/agent-worker/src/index.ts textlingo-desktop/agent-worker/src/runtime.ts textlingo-desktop/agent-worker/src/runtime.test.ts
git commit -m "refactor: replace worker shell with opencode runtime"
```

### Task 4: Rebuild the article tools adapter for the new runtime

**Files:**
- Create: `textlingo-desktop/agent-worker/src/tools/articleTools.ts`
- Test: `textlingo-desktop/agent-worker/src/tools/articleTools.test.ts`
- Modify: `textlingo-desktop/src-tauri/src/agent_worker.rs`
- Modify: `textlingo-desktop/src-tauri/tests/agent_worker_test.rs`

**Step 1: Write the failing test**

Add tests for:
- runtime tool adapters calling the expected Rust-side commands,
- `task.log` event propagation into the worker status snapshot,
- `task.result` / `task.error` handling through the new protocol.

**Step 2: Run test to verify it fails**

Run: `cargo test --test agent_worker_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: FAIL because Rust still expects the old worker protocol.

**Step 3: Write minimal implementation**

Keep the semantic tool surface the same, but update both sides for:
- new event names,
- new error payload shape,
- `task.log` buffering,
- `worker.ready` support.

**Step 4: Run test to verify it passes**

Run: `cargo test --test agent_worker_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/src/tools/articleTools.ts textlingo-desktop/agent-worker/src/tools/articleTools.test.ts textlingo-desktop/src-tauri/src/agent_worker.rs textlingo-desktop/src-tauri/tests/agent_worker_test.rs
git commit -m "feat: adapt article tools to opencode protocol"
```

### Task 5: Add the mind map recipe, prompt, and schema

**Files:**
- Create: `textlingo-desktop/agent-worker/src/recipes/mindMapRecipe.ts`
- Create: `textlingo-desktop/agent-worker/src/recipes/mindMapPrompt.ts`
- Create: `textlingo-desktop/agent-worker/src/recipes/mindMapSchema.ts`
- Test: `textlingo-desktop/agent-worker/src/recipes/mindMapRecipe.test.ts`

**Step 1: Write the failing test**

Add tests for:
- selecting `fast`, `balanced`, and `deep` modes from content length,
- returning `not_applicable` for empty or low-information content,
- validating the final `MindMapResult`,
- emitting recipe stage progress updates in the expected order.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/recipes/mindMapRecipe.test.ts`
Expected: FAIL because the recipe does not exist yet.

**Step 3: Write minimal implementation**

Implement the first OpenCode recipe with:
- stage-aware execution,
- raw-text-first rules,
- evidence grounding,
- mode selection,
- shared `MindMapResult` schema validation.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/recipes/mindMapRecipe.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/src/recipes/mindMapRecipe.ts textlingo-desktop/agent-worker/src/recipes/mindMapPrompt.ts textlingo-desktop/agent-worker/src/recipes/mindMapSchema.ts textlingo-desktop/agent-worker/src/recipes/mindMapRecipe.test.ts
git commit -m "feat: add opencode mind map recipe"
```

### Task 6: Integrate OpenCode execution into the recipe runtime

**Files:**
- Modify: `textlingo-desktop/agent-worker/src/runtime.ts`
- Modify: `textlingo-desktop/agent-worker/src/recipes/mindMapRecipe.ts`
- Test: `textlingo-desktop/agent-worker/src/runtime.integration.test.ts`

**Step 1: Write the failing test**

Add tests for:
- using normalized provider config to start the recipe,
- emitting `task.started`, `task.progress`, `task.log`, and `task.result`,
- surfacing provider auth failures as `provider_auth_error`.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.integration.test.ts`
Expected: FAIL because OpenCode execution is not yet wired into the recipe runtime.

**Step 3: Write minimal implementation**

Wire OpenCode execution into the worker:
- build per-task provider configuration,
- feed the recipe prompt and tool adapters,
- forward runtime logs as `task.log`,
- normalize provider and generation errors.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.integration.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/src/runtime.ts textlingo-desktop/agent-worker/src/recipes/mindMapRecipe.ts textlingo-desktop/agent-worker/src/runtime.integration.test.ts
git commit -m "feat: run mind map recipe through opencode"
```

### Task 7: Update Rust commands to pass the active model config into agent tasks

**Files:**
- Modify: `textlingo-desktop/src-tauri/src/commands.rs`
- Modify: `textlingo-desktop/src-tauri/src/storage.rs`
- Test: `textlingo-desktop/src-tauri/tests/mind_map_storage_test.rs`

**Step 1: Write the failing test**

Add tests that:
- ensure task creation captures enough model-config context for runtime execution,
- fail task creation when no active model config exists,
- preserve existing article task behavior.

**Step 2: Run test to verify it fails**

Run: `cargo test --test mind_map_storage_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: FAIL because task creation is still Claude-runtime-shaped.

**Step 3: Write minimal implementation**

Update task creation to:
- read the active model config,
- include the runtime-relevant model configuration in task input or request construction,
- fail fast with a clear app-level error when agent runtime cannot start from the current settings.

**Step 4: Run test to verify it passes**

Run: `cargo test --test mind_map_storage_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/commands.rs textlingo-desktop/src-tauri/src/storage.rs textlingo-desktop/src-tauri/tests/mind_map_storage_test.rs
git commit -m "feat: feed active model config into agent tasks"
```

### Task 8: Update the frontend for runtime-specific status and errors

**Files:**
- Modify: `textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx`
- Modify: `textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`
- Modify: `textlingo-desktop/src/locales/en.json`
- Modify: `textlingo-desktop/src/locales/zh.json`
- Modify: `textlingo-desktop/src/locales/ja.json`

**Step 1: Write the failing test**

Add tests for:
- rendering provider-auth failures clearly,
- rendering `task.log` entries with new sources,
- rendering unsupported-provider failures without opaque process-exit messages.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop && npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because the frontend still assumes the old runtime error/log shape.

**Step 3: Write minimal implementation**

Update the panel to:
- show normalized provider/runtime errors,
- render runtime logs from the new event stream,
- keep existing i18n and artifact rendering behavior.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop && npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx textlingo-desktop/src/locales/en.json textlingo-desktop/src/locales/zh.json textlingo-desktop/src/locales/ja.json
git commit -m "feat: surface opencode runtime logs and errors"
```

### Task 9: Remove Claude-specific runtime leftovers

**Files:**
- Modify: `textlingo-desktop/agent-worker/package.json`
- Delete or replace: Claude-specific runtime files under `textlingo-desktop/agent-worker/src/`
- Modify: `textlingo-desktop/src-tauri/src/agent_worker.rs`
- Test: `textlingo-desktop/agent-worker/src/runtime.test.ts`

**Step 1: Write the failing test**

Add tests that assert:
- no task path requires Claude-specific executable configuration,
- no Claude-only error wording remains in runtime logs,
- the worker can start without Claude Code installed.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.test.ts`
Expected: FAIL because Claude-specific dependencies and assumptions still exist.

**Step 3: Write minimal implementation**

Remove or replace:
- `@anthropic-ai/claude-agent-sdk`
- Claude-specific worker launch assumptions
- Claude-specific log strings and config plumbing

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/package.json textlingo-desktop/agent-worker/src textlingo-desktop/src-tauri/src/agent_worker.rs
git commit -m "refactor: remove claude runtime dependency"
```

### Task 10: Full verification of the OpenCode mind map path

**Files:**
- Verify existing files touched above

**Step 1: Run worker test suite**

Run: `cd textlingo-desktop/agent-worker && npm test`
Expected: PASS

**Step 2: Run worker build**

Run: `cd textlingo-desktop/agent-worker && npm run build`
Expected: PASS

**Step 3: Run focused frontend tests**

Run: `cd textlingo-desktop && npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS

**Step 4: Run frontend typecheck**

Run: `cd textlingo-desktop && npm run typecheck`
Expected: PASS

**Step 5: Run Rust tests**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 6: Manual verification**

Run the desktop app from the worktree and verify:
- active settings model config is used,
- a supported provider starts a mind map task,
- task logs are readable,
- unsupported providers fail fast with a clear message,
- generated artifacts still render in the article reader.

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: migrate embedded agent runtime to opencode"
```
