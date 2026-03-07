# OpenCode Agent Runtime Migration Design

**Date:** 2026-03-07

**Goal:** Replace the embedded Claude-based agent runtime with an OpenCode-based runtime while keeping the desktop app's existing settings, task storage, artifact storage, and article data model intact.

## Problem

The current embedded agent worker is tightly coupled to Claude-specific runtime concepts:

- `@anthropic-ai/claude-agent-sdk`
- Claude Code authentication and CLI lifecycle
- Claude-local skills
- Claude-flavored MCP server integration
- Claude-specific streaming and failure behavior

This creates three product problems:

1. The runtime fails if Claude Code authentication expires or is unavailable.
2. The runtime does not align with the app's existing multi-provider settings model.
3. Future agent features such as PPT generation and long-form document tasks would remain locked to the Claude toolchain.

The desktop app already has a model configuration system with `api_provider`, `api_key`, `model`, and optional `base_url`, and it already uses those settings in other AI flows. The new agent runtime should align with that system instead of introducing a second model configuration path.

## Scope

- Replace the current Claude worker runtime with an OpenCode-based runtime.
- Rework the worker protocol and event stream around the new runtime.
- Reuse the existing desktop model configuration system.
- Reuse Rust/Tauri task persistence, artifact persistence, and article storage.
- Reuse the existing article tool semantics: overview, read window, search, evidence, progress, artifact save.
- Implement the new runtime first for `mind_map.generate`.
- Keep the design extensible for future `ppt.outline`, `ppt.slides`, and `article.ask`.

## Non-goals

- No migration of article storage away from local JSON files.
- No redesign of the settings UI in this phase beyond what is needed to surface runtime support.
- No full visual graph editor for mind maps in this phase.
- No attempt to support every provider in settings as a guaranteed first-class agent provider on day one.

## Architecture

### Three-layer model

The migrated system keeps the same high-level topology:

- **React/Tauri UI**
  - Starts tasks
  - Shows progress, logs, errors, and artifacts
  - Remains runtime-agnostic
- **Rust/Tauri app core**
  - Owns article data, tasks, artifacts, and worker lifecycle
  - Emits app-friendly status updates to the frontend
  - Exposes controlled document tools to the runtime worker
- **OpenCode worker**
  - Owns provider execution and agent orchestration
  - Resolves provider configuration
  - Runs task recipes
  - Emits normalized task and worker events

Rust remains the source-of-truth layer. The worker must not directly own or mutate article files.

### Runtime replacement strategy

This is a runtime migration, not a storage migration.

The following layers remain stable:

- `Article`
- `AgentTask`
- `Artifact`
- current task directories and artifact directories
- article reader mind map panel
- Rust-controlled article/evidence tools

The following layers are replaced:

- Claude SDK integration
- Claude Code executable dependency
- Claude skill loading model
- Claude-specific MCP setup
- Claude-specific stream handling

## Provider Model

The user-facing provider settings remain unchanged. Internally, the runtime normalizes those settings into execution kinds:

- `openai_compatible`
- `native_google`
- `native_anthropic`
- `unsupported`

### Initial mapping

**Stable first-phase support**

- `openai`
- `openai-compatible`
- `openrouter`
- `google`
- `google-ai-studio`
- `anthropic`

**Experimental support**

- `ollama`
- `lmstudio`

**Conditional support**

- `302ai`
- `siliconflow`
- `moonshot`
- `deepseek`

Conditional providers can run only if they behave as compatible chat providers for the required agent features. Otherwise they must fail fast with a runtime support error.

### Why not treat everything as OpenAI-compatible

Many providers expose partial OpenAI-like APIs but differ in one or more of:

- model naming
- tool calling
- structured output
- streaming event shape
- endpoint semantics

The runtime must not assume that all configured providers can be used interchangeably for agent tasks.

## OpenCode Runtime Strategy

### Configuration

The worker should receive normalized provider configuration built from the current active model config. This avoids duplicating configuration logic in the frontend.

OpenCode provider configuration should be assembled per task from:

- provider kind
- provider id
- model id
- API key
- base URL when needed

The worker should support custom provider definitions for OpenAI-compatible backends via base URL.

### Rules / instructions

The current Claude-local skill system is replaced by OpenCode-compatible instructions and task recipes.

For the first phase:

- do not re-create a general-purpose skill framework,
- do not bind runtime behavior to Claude-specific `.claude/skills`,
- do define task-specific recipe prompts and schemas inside the worker package.

This keeps migration scope contained and avoids carrying Claude runtime assumptions into the new stack.

## Mind Map Recipe

`mind_map.generate` becomes the first OpenCode recipe.

### Core principles

- Raw source text remains the semantic source of truth.
- The recipe may use article tools, but cannot bypass them.
- The recipe must return the agreed JSON `MindMapResult`.
- The recipe may return `partial` or `not_applicable`.
- The recipe must prefer grounded nodes and evidence anchors over broad ungrounded prose.

### Execution modes

The recipe supports:

- `fast`
- `balanced`
- `deep`

The runtime chooses a default mode from content length and content type:

- short content favors `fast`
- medium content favors `balanced`
- long or complex content favors `deep`

### Recipe stages

The runtime should expose stage-aware execution:

- `inspecting`
- `reading`
- `structuring`
- `evidence`
- `validating`
- `saving`

These stages drive frontend progress UI and runtime logs.

## Tool Layer

The existing Rust-controlled tool semantics remain valid:

- `article_get_overview`
- `article_read_window`
- `article_search`
- `article_get_evidence`
- `task_report_progress`
- `artifact_save`

The migration changes how the worker registers and consumes tools, but not what those tools mean.

This preserves:

- evidence grounding
- Rust-owned data access
- compatibility with the current article storage format

## Protocol

### Request entry point

The new worker request entry point is normalized around agent runs:

```json
{
  "id": "req_xxx",
  "type": "request",
  "method": "agent.run",
  "params": {
    "task_id": "task_xxx",
    "task_type": "mind_map.generate",
    "provider_config": {
      "kind": "native_google",
      "provider": "google",
      "model": "gemini-2.0-flash-exp",
      "api_key": "..."
    },
    "input": {
      "article_id": "article_xxx",
      "display_language": "zh-CN",
      "max_depth": 3,
      "mode": "balanced"
    }
  }
}
```

### Event stream

The worker emits a runtime-neutral event stream:

- `worker.ready`
- `worker.heartbeat`
- `task.started`
- `task.progress`
- `task.log`
- `task.result`
- `task.error`

This replaces the previous Claude-flavored event behavior.

### Error model

Errors must be explicit and categorized. Suggested codes:

- `provider_auth_error`
- `provider_unsupported`
- `provider_rate_limited`
- `provider_timeout`
- `tool_error`
- `validation_error`
- `generation_error`
- `internal_error`

The app should never reduce a provider failure to an opaque process-exit-only message if the runtime can surface a better explanation.

## Data Model Impact

### Stable

- `Article`
- `AgentTask`
- `Artifact`
- `MindMapResult`
- existing task and artifact directories

### New runtime concerns

The worker status snapshot should continue to include:

- runtime health
- session id
- started timestamp
- last heartbeat timestamp
- recent log entries

The frontend should remain subscribed to app-level events such as:

- `agent-task-updated`
- `agent-worker-status`

Rust remains the aggregation layer between worker protocol and UI state.

## Boundary Handling

### Unsupported providers

If a configured provider cannot support the required agent runtime features, the task must fail fast with:

- clear error code
- human-readable reason
- suggestion to switch to a supported provider

### Authentication failures

The runtime must surface provider authentication failures directly. It should not rely on low-information process-exit messages.

### Long content

Long content must use recipe modes and staged reading. The migration does not justify regressing to a naive full-document single-shot prompt.

### Music-only / low-information content

The recipe must still return `not_applicable` for content that does not support meaningful structural extraction.

## Verification

The migration must be verified at four levels:

- worker provider resolution tests
- worker protocol / recipe tests
- Rust integration tests for the new worker protocol handling
- frontend tests for progress/log/error rendering

End-to-end verification must confirm that the active model config in settings is actually used by the new runtime.

## References

- OpenCode providers docs: [https://opencode.ai/docs/providers/](https://opencode.ai/docs/providers/)
- OpenCode config docs: [https://opencode.ai/docs/config](https://opencode.ai/docs/config)
- OpenCode overview: [https://dev.opencode.ai/](https://dev.opencode.ai/)
