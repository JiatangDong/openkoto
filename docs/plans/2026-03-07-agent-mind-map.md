# Agent-Driven Mind Map Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an embedded agent-worker pipeline that generates article-level, evidence-grounded mind maps as reusable JSON artifacts in the desktop app.

**Architecture:** Add a Node-based agent worker that runs the Claude Agent SDK and a project-local `generate-mindmap` skill, while Rust/Tauri remains the source-of-truth layer for content access, task state, and artifact persistence. The worker communicates only through controlled tool calls and writes a schema-validated `mind_map` artifact that the article reader can render in a new sidebar tab.

**Tech Stack:** Tauri v2, Rust, React 19, TypeScript, Node.js, `@anthropic-ai/claude-agent-sdk`, MCP tools, Zod/JSON Schema, Vitest, Rust tests

---

### Task 1: Define task and artifact domain types

**Files:**
- Modify: `textlingo-desktop/src-tauri/src/types.rs`
- Modify: `textlingo-desktop/src/types/index.ts`
- Modify: `textlingo-desktop/src/lib/tauri.ts`

**Step 1: Write the failing test**

Add Rust serialization tests covering:
- `AgentTask` round-trip serialization,
- `Artifact` round-trip serialization,
- `MindMapResult` success / partial / not_applicable payloads.

**Step 2: Run test to verify it fails**

Run: `cargo test mind_map --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: FAIL because the new task, artifact, and mind map types do not exist yet.

**Step 3: Write minimal implementation**

Add Rust and TypeScript types for:
- `AgentTask`,
- `Artifact`,
- `MindMapResult`,
- `MindMap`,
- `MindMapNode`,
- diagnostics and enum values,
- `Article.active_mind_map_artifact_id`.

**Step 4: Run test to verify it passes**

Run: `cargo test mind_map --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/types.rs textlingo-desktop/src/types/index.ts textlingo-desktop/src/lib/tauri.ts
git commit -m "feat: add agent task and mind map domain types"
```

### Task 2: Add task and artifact persistence in Rust

**Files:**
- Modify: `textlingo-desktop/src-tauri/src/storage.rs`
- Modify: `textlingo-desktop/src-tauri/src/commands.rs`
- Test: `textlingo-desktop/src-tauri/tests/mind_map_storage_test.rs`

**Step 1: Write the failing test**

Create tests that:
- save and load an `AgentTask`,
- save and load an `Artifact`,
- update an article with `active_mind_map_artifact_id`,
- preserve unrelated article fields.

**Step 2: Run test to verify it fails**

Run: `cargo test --test mind_map_storage_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: FAIL because task/artifact storage helpers and article field updates are missing.

**Step 3: Write minimal implementation**

Add storage directories and helpers for:
- `agent_tasks/<task_id>.json`,
- `artifacts/articles/<article_id>/<artifact_id>.json`.

Add Rust commands/helpers to:
- create task records,
- update task progress/status,
- save artifacts,
- set the active mind map artifact on an article.

**Step 4: Run test to verify it passes**

Run: `cargo test --test mind_map_storage_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/storage.rs textlingo-desktop/src-tauri/src/commands.rs textlingo-desktop/src-tauri/tests/mind_map_storage_test.rs
git commit -m "feat: persist agent tasks and mind map artifacts"
```

### Task 3: Add Rust commands for mind map tasks and controlled content tools

**Files:**
- Modify: `textlingo-desktop/src-tauri/src/commands.rs`
- Modify: `textlingo-desktop/src-tauri/src/lib.rs`
- Test: `textlingo-desktop/src-tauri/tests/mind_map_tools_test.rs`

**Step 1: Write the failing test**

Create tests for:
- `article_get_overview`,
- `article_read_window`,
- `article_search`,
- `article_get_evidence`,
- `task_report_progress`,
- `artifact_save`.

The tests should verify stable shapes, correct evidence ids, and safe window boundaries.

**Step 2: Run test to verify it fails**

Run: `cargo test --test mind_map_tools_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: FAIL because the commands and helpers are not implemented.

**Step 3: Write minimal implementation**

Add new Tauri commands and internal helpers that:
- inspect article metadata,
- read raw article text in cursor-based windows,
- return matching segments for simple search,
- return evidence records by segment id,
- update task progress,
- save the `mind_map` artifact payload.

Register the commands in `src-tauri/src/lib.rs`.

**Step 4: Run test to verify it passes**

Run: `cargo test --test mind_map_tools_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/commands.rs textlingo-desktop/src-tauri/src/lib.rs textlingo-desktop/src-tauri/tests/mind_map_tools_test.rs
git commit -m "feat: add controlled mind map content tools"
```

### Task 4: Scaffold the embedded agent worker package

**Files:**
- Create: `textlingo-desktop/agent-worker/package.json`
- Create: `textlingo-desktop/agent-worker/tsconfig.json`
- Create: `textlingo-desktop/agent-worker/src/index.ts`
- Create: `textlingo-desktop/agent-worker/src/protocol.ts`
- Create: `textlingo-desktop/agent-worker/src/runtime.ts`
- Test: `textlingo-desktop/agent-worker/src/runtime.test.ts`

**Step 1: Write the failing test**

Add worker-side tests for:
- task request parsing,
- progress event emission,
- result schema validation failure handling.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.test.ts`
Expected: FAIL because the worker package and runtime entry do not exist.

**Step 3: Write minimal implementation**

Create the standalone Node package, add the Claude Agent SDK dependency scaffolding, and implement:
- stdio protocol parsing,
- task dispatch entry points,
- Rust IPC adapter stubs,
- schema validation hooks,
- worker heartbeat state.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/runtime.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/package.json textlingo-desktop/agent-worker/tsconfig.json textlingo-desktop/agent-worker/src/index.ts textlingo-desktop/agent-worker/src/protocol.ts textlingo-desktop/agent-worker/src/runtime.ts textlingo-desktop/agent-worker/src/runtime.test.ts
git commit -m "feat: scaffold embedded agent worker"
```

### Task 5: Add the `generate-mindmap` skill and schema

**Files:**
- Create: `textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/SKILL.md`
- Create: `textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/schemas/mind-map.schema.json`
- Create: `textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/prompts/evidence-first.md`
- Create: `textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/prompts/not-applicable.md`
- Test: `textlingo-desktop/agent-worker/src/mindMapSchema.test.ts`

**Step 1: Write the failing test**

Add tests that:
- validate the schema accepts `applicable`, `partial`, and `not_applicable`,
- reject missing root nodes or invalid confidence values,
- ensure required enums and fields match the agreed contract.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/mindMapSchema.test.ts`
Expected: FAIL because the skill files and schema do not exist.

**Step 3: Write minimal implementation**

Add the project-local skill, result schema, and supporting prompt fragments with rules for:
- raw-text-first generation,
- incremental reading for long content,
- evidence attachment,
- boundary handling for music-only or low-information sources.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/mindMapSchema.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/SKILL.md textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/schemas/mind-map.schema.json textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/prompts/evidence-first.md textlingo-desktop/agent-worker/.claude/skills/generate-mindmap/prompts/not-applicable.md textlingo-desktop/agent-worker/src/mindMapSchema.test.ts
git commit -m "feat: add generate-mindmap skill and schema"
```

### Task 6: Wire the worker to the Claude Agent SDK and MCP tools

**Files:**
- Modify: `textlingo-desktop/agent-worker/src/runtime.ts`
- Create: `textlingo-desktop/agent-worker/src/mcp/textlingoServer.ts`
- Create: `textlingo-desktop/agent-worker/src/mindMapTask.ts`
- Test: `textlingo-desktop/agent-worker/src/mindMapTask.test.ts`

**Step 1: Write the failing test**

Add tests that:
- verify the worker starts a `mind_map.generate` task,
- confirm the SDK runtime is configured with project skills enabled,
- confirm only the intended MCP tools are exposed,
- validate parsed mind map output is saved through the save adapter.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/mindMapTask.test.ts`
Expected: FAIL because the SDK query integration and MCP server wiring are missing.

**Step 3: Write minimal implementation**

Integrate the Claude Agent SDK with:
- explicit `pathToClaudeCodeExecutable`,
- project skill loading,
- controlled MCP tool exposure,
- JSON schema output formatting,
- task progress forwarding,
- artifact save on successful completion.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop/agent-worker && npm test -- src/mindMapTask.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/agent-worker/src/runtime.ts textlingo-desktop/agent-worker/src/mcp/textlingoServer.ts textlingo-desktop/agent-worker/src/mindMapTask.ts textlingo-desktop/agent-worker/src/mindMapTask.test.ts
git commit -m "feat: connect agent worker to mind map skill"
```

### Task 7: Add Rust worker lifecycle management and IPC

**Files:**
- Modify: `textlingo-desktop/src-tauri/src/commands.rs`
- Modify: `textlingo-desktop/src-tauri/src/main.rs`
- Modify: `textlingo-desktop/src-tauri/src/lib.rs`
- Create: `textlingo-desktop/src-tauri/src/agent_worker.rs`
- Test: `textlingo-desktop/src-tauri/tests/agent_worker_test.rs`

**Step 1: Write the failing test**

Add tests for:
- worker start / stop lifecycle,
- task submission routing,
- heartbeat timeout handling,
- interrupted task recovery behavior.

**Step 2: Run test to verify it fails**

Run: `cargo test --test agent_worker_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: FAIL because the worker manager and IPC flow do not exist.

**Step 3: Write minimal implementation**

Add a Rust worker manager that:
- launches the embedded Node worker,
- tracks worker health,
- sends task requests over stdio JSON messages,
- receives progress / result events,
- updates persisted task records,
- emits Tauri events for the frontend.

**Step 4: Run test to verify it passes**

Run: `cargo test --test agent_worker_test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/agent_worker.rs textlingo-desktop/src-tauri/src/commands.rs textlingo-desktop/src-tauri/src/main.rs textlingo-desktop/src-tauri/src/lib.rs textlingo-desktop/src-tauri/tests/agent_worker_test.rs
git commit -m "feat: add embedded agent worker manager"
```

### Task 8: Add frontend task API and mind map sidebar UI

**Files:**
- Modify: `textlingo-desktop/src/components/features/ArticleReader.tsx`
- Create: `textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx`
- Create: `textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx`
- Modify: `textlingo-desktop/src/types/index.ts`
- Modify: `textlingo-desktop/src/lib/tauri.ts`

**Step 1: Write the failing test**

Add component tests that:
- render the new `Mind Map` tab,
- show generate CTA before a task exists,
- show progress during generation,
- show not-applicable empty state,
- render a successful tree result.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop && npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: FAIL because the new tab and panel do not exist.

**Step 3: Write minimal implementation**

Add:
- the third sidebar tab in `ArticleReader`,
- the article-level mind map panel,
- task create / poll / event wiring,
- basic tree rendering for the `mind_map` artifact.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop && npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/ArticleReader.tsx textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx textlingo-desktop/src/components/features/ArticleMindMapPanel.test.tsx textlingo-desktop/src/types/index.ts textlingo-desktop/src/lib/tauri.ts
git commit -m "feat: add article mind map sidebar UI"
```

### Task 9: Add end-to-end verification for the mind map flow

**Files:**
- Create: `textlingo-desktop/e2e/mind-map-flow.spec.ts`
- Modify: `textlingo-desktop/playwright.config.ts` (if needed)

**Step 1: Write the failing test**

Create an end-to-end flow that:
- opens an article,
- starts a mind map task,
- receives progress,
- renders a final tree or not-applicable state.

Use a mocked worker response path if full SDK execution is too heavy for CI.

**Step 2: Run test to verify it fails**

Run: `cd textlingo-desktop && npx playwright test e2e/mind-map-flow.spec.ts`
Expected: FAIL because the flow and UI hooks are not implemented.

**Step 3: Write minimal implementation**

Add the e2e flow and any required lightweight worker/test doubles so the UI can be verified deterministically.

**Step 4: Run test to verify it passes**

Run: `cd textlingo-desktop && npx playwright test e2e/mind-map-flow.spec.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add textlingo-desktop/e2e/mind-map-flow.spec.ts textlingo-desktop/playwright.config.ts
git commit -m "test: cover mind map task flow"
```

### Task 10: Run final verification and update docs

**Files:**
- Modify: `README.md` (if runtime/feature docs are needed)
- Modify: `README_cn.md` (if runtime/feature docs are needed)
- Modify: `README_ja.md` (if runtime/feature docs are needed)
- Test: Rust and frontend verification targets

**Step 1: Run worker tests**

Run: `cd textlingo-desktop/agent-worker && npm test`
Expected: PASS

**Step 2: Run frontend tests**

Run: `cd textlingo-desktop && npm test -- src/components/features/ArticleMindMapPanel.test.tsx`
Expected: PASS

**Step 3: Run Rust tests**

Run: `cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml`
Expected: PASS

**Step 4: Run typechecks**

Run: `cd textlingo-desktop && npm run typecheck`
Expected: PASS

**Step 5: Review status and commit**

```bash
git status --short
```

Review generated worker/runtime artifacts and docs before any final commit.
