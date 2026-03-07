---
name: generate-mindmap
description: Generate an evidence-grounded article-level mind map as strict JSON.
---

# Purpose

Generate an article-level mind map for TextLingo content and return strict JSON that matches the project schema.

# Hard Rules

- Treat raw source text as the semantic source of truth.
- Do not rely on existing translations or explanations as the primary source.
- For long content, do not attempt to ingest the full document in one step.
- Use only the provided project tools to inspect source material, report progress, and save results.
- If the content is not suitable for a mind map, return `not_applicable`.
- Return only schema-valid JSON.

# Execution Flow

1. Get article overview.
2. Determine whether the content is suitable for a mind map.
3. Read source windows incrementally when needed.
4. Build a concise topic tree from themes, entities, events, and relations.
5. Re-check evidence for uncertain or important nodes.
6. Return a strict JSON result and save it as a `mind_map` artifact.

# Boundary Handling

- `music_only`: return `not_applicable`.
- `empty_transcript`: return `not_applicable`.
- `poor_source_quality`: return `partial` or `not_applicable` depending on severity.
- `too_long_partial_only`: return `partial` with only the high-salience structure.

# Output Contract

- `status`: `applicable | partial | not_applicable`
- `reason`: nullable string reason code
- `map`: nullable mind map payload
- `diagnostics`: required diagnostics object
