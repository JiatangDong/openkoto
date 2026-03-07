import { test } from "@playwright/test";

test.describe("Mind map generation flow", () => {
  test.skip(
    true,
    "Desktop Tauri E2E requires a platform-specific harness; the flow is covered by component tests and worker IPC smoke checks.",
  );

  test("open article -> generate mind map -> receive progress -> render result", async () => {
    // Acceptance contract for future tauri-driver coverage:
    // 1. Open an article in the reader.
    // 2. Switch to the Mind Map sidebar tab.
    // 3. Start `mind_map.generate`.
    // 4. Observe task progress events in the sidebar.
    // 5. Render either the final topic tree or the not-applicable empty state.
  });
});
