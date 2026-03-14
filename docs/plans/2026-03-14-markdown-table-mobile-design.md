# Markdown Table Mobile Design

**Goal:** Improve narrow-screen rendering for AI-generated Markdown tables while preserving standard table semantics and horizontal scrolling.

## Scope

- Shared AI Markdown renderer only
- Agent replies
- Article chat replies
- Explanation notes
- Analysis results

Out of scope:

- Article body Markdown rendering in `ArticleReader`
- Converting tables into cards or other non-table layouts

## Design

Keep standard `<table>` output and enhance the shared renderer in three places:

1. Table scroll wrapper
   Add mobile-friendly horizontal scrolling behavior so swiping the table is smoother and better isolated from parent scroll containers.

2. Table width strategy
   Stop forcing the table into a fully stretched layout on small screens. Use content-driven width with a minimum of the available container width so short tables still fill the bubble while wide tables can scroll naturally.

3. Cell wrapping
   Allow long values to wrap inside cells instead of blowing out the whole table. This keeps narrow screens readable without losing semantic structure.

## Testing

- Add a renderer test that asserts the table wrapper uses the mobile scrolling classes.
- Assert the rendered table and cells include the new width and wrapping classes.
