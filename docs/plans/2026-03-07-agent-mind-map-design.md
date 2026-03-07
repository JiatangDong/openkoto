# Agent-Driven Mind Map Design

**Date:** 2026-03-07

**Goal:** Add an article-level mind map capability driven by an embedded long-running agent worker while keeping Rust/Tauri as the source-of-truth content and storage layer.

## Problem

The current desktop app can import content, extract subtitles, split content into segments, and generate per-segment explanations, but it does not support article-level structure generation such as mind maps. A naive "send the full document to a model" approach does not scale to long books, long subtitle transcripts, or noisy audio/video material. A pure segment-summary pipeline risks losing long-range context and evidence.

The product direction also requires a reusable AI task foundation for future features such as PPT generation and deeper document question answering. That makes a one-off in-process mind map feature the wrong long-term shape.

## Scope

- Add a local embedded agent worker process for long-running AI tasks.
- Add a `mind_map.generate` task type.
- Let the agent drive reading strategy and node generation through a dedicated `generate-mindmap` skill.
- Keep article data, task state, artifacts, and evidence lookups inside the Rust/Tauri layer.
- Store the generated result as a reusable, schema-validated JSON artifact.
- Prepare the architecture so future agent tasks can reuse the same runtime and task system.

## Non-goals

- No PPT generation in this phase.
- No editable visual mind-map canvas in this phase.
- No remote agent service in this phase.
- No replacement of the current translation / explanation flows.
- No full database migration; file-based storage remains the persistence model.

## Architecture

### Runtime model

The feature uses three layers:

- React/Tauri UI for task creation, progress display, and mind map rendering.
- Rust/Tauri app core for source-of-truth content access, task persistence, artifact persistence, and worker lifecycle management.
- A bundled Node-based agent worker that runs the Claude Agent SDK and the project skill set.

The Node worker is an AI runtime only. It does not own article files, does not directly mutate stored article JSON, and does not bypass Rust for file access or artifact writes.

### Claude Agent SDK integration

The worker uses `@anthropic-ai/claude-agent-sdk` and an embedded Claude Code executable. The app should launch the worker with an explicit path to the bundled Claude Code binary instead of relying on a user-installed `claude` command. The worker enables project-local skills and exposes only the controlled project MCP tools needed for mind map generation.

### Agent strategy

The mind map is agent-driven, not Rust-scripted. The `generate-mindmap` skill determines:

- whether the source is suitable for a mind map,
- whether it can read broadly or must read incrementally,
- how to form major themes and subtopics,
- when to re-read evidence for uncertain nodes,
- when to return `partial` or `not_applicable`.

The agent must treat raw source text as the semantic source of truth. Existing segment translations and explanations are not the primary input for map generation.

### Rust-controlled tools

Rust exposes a narrow tool surface to the agent:

- `article_get_overview`
- `article_read_window`
- `article_search`
- `article_get_evidence`
- `task_report_progress`
- `artifact_save`

These tools let the agent inspect the document, read original text in controlled windows, ground nodes in evidence, and save output, while preventing arbitrary file system access.

## Data Model

### Article

`Article` remains the content source of truth. The only new article-level field needed in this phase is a pointer to the currently active mind map artifact, for example `active_mind_map_artifact_id`.

### AgentTask

Agent work is stored separately from articles. Each task records:

- task identity and type,
- associated article,
- structured input,
- status and progress,
- timestamps,
- worker session identity,
- related artifact ids,
- last error, if any.

This supports long-running jobs, cancellation, retry, and future reuse by non-mind-map agent tasks.

### Artifact

Generated output is stored as independent artifacts. A mind map run writes one `mind_map` artifact containing schema-valid JSON. This allows multiple generated versions per article and avoids polluting `Article` with large AI outputs.

## Mind Map Result Contract

The agent writes a top-level result object with:

- `status`: `applicable | partial | not_applicable`
- `reason`: nullable reason code
- `map`: nullable mind map payload
- `diagnostics`: content-type and coverage diagnostics

The `map` payload contains:

- schema version,
- article id,
- display language,
- generation mode,
- source hash,
- short map summary,
- root node.

Each node contains:

- `id`
- `title`
- `node_type`
- `summary`
- `confidence`
- `source_segment_ids`
- optional `source_offsets`
- optional `time_range`
- `children`

This gives the UI enough structure to render a tree view now and power future node-to-evidence jumps, exports, and PPT outline generation later.

## Boundary Handling

### Very long books or subtitle transcripts

The agent must not ingest the full article at once for long content. It reads through `article_read_window`, forms a high-salience topic tree, and may return `partial` coverage when appropriate. The first release should favor a stable 2-3 level tree over an exhaustive but low-confidence map.

### Music-only or low-information audio

If the source is mostly music, ambient audio, or contains no stable semantic material, the agent returns `not_applicable` with a reason such as `music_only` or `empty_transcript`. The UI should show an explanatory empty state rather than forcing a fake map.

### Poor transcript quality

If the extracted text is too noisy to support grounded structure, the agent returns `partial` or `not_applicable` with `poor_source_quality`, depending on severity. Diagnostics should explain why coverage is limited.

### Mixed-language or dialogue-heavy sources

The agent may generate node labels in the requested display language while grounding all claims in the original text via segment ids and optional offsets. Dialogue-heavy content should prefer theme, event, and relation nodes over unsupported abstract conclusions.

## UI Design

The current right sidebar in the article reader has `Explanation` and `Chat`. This phase adds a third article-level `Mind Map` tab. The tab is task-driven:

- before generation: show a generate CTA and short capability note,
- during generation: show task stage and progress,
- success: render the tree using the saved artifact,
- not applicable / partial: render the corresponding status and diagnostics.

The initial renderer can be a structured collapsible tree view rather than a freeform graph editor.

## Verification

The implementation should include:

- Rust unit tests for task/artifact persistence and tool behavior,
- worker-side tests for schema validation and result handling,
- frontend tests for mind map tab states,
- end-to-end verification of task creation, progress updates, and final artifact rendering.
