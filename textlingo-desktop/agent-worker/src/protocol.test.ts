import { describe, expect, it } from "vitest";

import {
  createTaskErrorEvent,
  createTaskLogEvent,
  createTaskStartedEvent,
  createWorkerReadyEvent,
  parseAgentRunRequest,
} from "./protocol.js";

describe("protocol", () => {
  it("parses an agent.run request with provider config", () => {
    const request = parseAgentRunRequest(
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

    expect(request.method).toBe("agent.run");
    expect(request.params.provider_config.kind).toBe("native_google");
    expect(request.params.input.article_id).toBe("article-1");
    expect(request.params.input.article_snapshot.title).toBe("Sample Article");
  });

  it("creates worker and task lifecycle events", () => {
    const ready = createWorkerReadyEvent("worker-1", "opencode", "0.1.0");
    const started = createTaskStartedEvent("task-1", "mind_map.generate");
    const log = createTaskLogEvent("task-1", "info", "provider", "Gemini request started");
    const error = createTaskErrorEvent("task-1", "provider_auth_error", "Authentication failed", "bad key");

    expect(ready.event).toBe("worker.ready");
    expect(started.event).toBe("task.started");
    expect(log.payload.source).toBe("provider");
    expect(error.payload.code).toBe("provider_auth_error");
  });
});
