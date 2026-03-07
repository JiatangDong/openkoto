import { describe, expect, it, vi } from "vitest";

import { createWorkerHost } from "./index.js";

describe("worker host", () => {
  it("emits worker.ready on startup", () => {
    const events: unknown[] = [];

    createWorkerHost({
      workerSessionId: "worker-1",
      version: "0.1.0",
      writeEvent: (event) => events.push(event),
      runAgentTask: async () => undefined,
    });

    expect(events[0]).toMatchObject({
      type: "event",
      event: "worker.ready",
      payload: {
        worker_session_id: "worker-1",
        runtime: "opencode",
        version: "0.1.0",
      },
    });
  });

  it("handles agent.run lines through the new runtime entry", async () => {
    const events: unknown[] = [];
    const runAgentTask = vi.fn(async () => undefined);

    const host = createWorkerHost({
      workerSessionId: "worker-1",
      version: "0.1.0",
      writeEvent: (event) => events.push(event),
      runAgentTask,
    });

    await host.handleLine(
      JSON.stringify({
        id: "req-1",
        type: "request",
        method: "agent.run",
        params: {
          task_id: "task-1",
          task_type: "mind_map.generate",
          provider_config: {
            kind: "native_google",
            provider: "google",
            model: "gemini-2.0-flash-exp",
            api_key: "secret",
          },
          input: {
            article_id: "article-1",
            display_language: "zh-CN",
            max_depth: 3,
            mode: "balanced",
            article_snapshot: {
              title: "Sample Article",
              content: "Alpha beta gamma.",
              source_type: "article",
            },
          },
        },
      }),
    );

    expect(runAgentTask).toHaveBeenCalledTimes(1);
    expect(events.some((event: any) => event.event === "task.started")).toBe(true);
  });
});
