import { describe, expect, it } from "vitest";

import {
  createTaskErrorEvent,
  createTaskStartedEvent,
  createErrorEvent,
  createHeartbeatEvent,
  createProgressEvent,
  createResultEvent,
  handleAgentRunRequest,
  parseWorkerRequest,
  parseAgentRunRequest,
  validateMindMapResult,
} from "./runtime.js";

describe("runtime", () => {
  it("parses a task request payload", () => {
    const request = parseWorkerRequest(
      JSON.stringify({
        id: "req-1",
        type: "request",
        method: "task.start",
        params: {
          task_id: "task-1",
          task_type: "mind_map.generate",
          payload: {
            article_id: "article-1",
          },
        },
      }),
    );

    expect(request.method).toBe("task.start");
    expect(request.params.task_id).toBe("task-1");
    expect(request.params.payload.article_id).toBe("article-1");
  });

  it("creates progress events with normalized payload", () => {
    const event = createProgressEvent("task-1", "reading", 0.4, "Reading source");

    expect(event.type).toBe("event");
    expect(event.event).toBe("task.progress");
    expect(event.payload.task_id).toBe("task-1");
    expect(event.payload.progress).toBe(0.4);
  });

  it("creates heartbeat events", () => {
    const event = createHeartbeatEvent("worker-1");

    expect(event.type).toBe("event");
    expect(event.event).toBe("worker.heartbeat");
    expect(event.payload.worker_session_id).toBe("worker-1");
  });

  it("creates result events", () => {
    const event = createResultEvent("task-1", { status: "applicable" });

    expect(event.event).toBe("task.result");
    expect(event.payload.task_id).toBe("task-1");
  });

  it("creates error events", () => {
    const event = createErrorEvent("task-1", "boom");

    expect(event.event).toBe("task.error");
    expect(event.payload.message).toBe("boom");
  });

  it("rejects invalid mind map results", () => {
    expect(() =>
      validateMindMapResult({
        status: "applicable",
        map: null,
      }),
    ).toThrow(/diagnostics/i);
  });

  it("parses an agent.run request", () => {
    const request = parseAgentRunRequest(
      JSON.stringify({
        id: "req-2",
        type: "request",
        method: "agent.run",
        params: {
          task_id: "task-2",
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
    expect(request.params.input.article_id).toBe("article-1");
  });

  it("emits task.started before executing an agent run request", async () => {
    const writes: unknown[] = [];

    await handleAgentRunRequest(
      parseAgentRunRequest(
        JSON.stringify({
          id: "req-2",
          type: "request",
          method: "agent.run",
          params: {
            task_id: "task-2",
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
      ),
      {
        writeEvent: (event) => writes.push(event),
        runTask: async () => undefined,
      },
    );

    expect(writes[0]).toMatchObject({
      type: "event",
      event: "task.started",
      payload: {
        task_id: "task-2",
        task_type: "mind_map.generate",
      },
    });
  });

  it("emits a normalized task.error for unsupported providers", async () => {
    const writes: unknown[] = [];

    await handleAgentRunRequest(
      parseAgentRunRequest(
        JSON.stringify({
          id: "req-3",
          type: "request",
          method: "agent.run",
          params: {
            task_id: "task-3",
            task_type: "mind_map.generate",
            provider_config: {
              kind: "unsupported",
              provider: "weird-provider",
              reason: "Provider weird-provider is not supported for the agent runtime",
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
      ),
      {
        writeEvent: (event) => writes.push(event),
        runTask: async () => undefined,
      },
    );

    expect(writes[0]).toMatchObject({
      type: "event",
      event: "task.started",
      payload: {
        task_id: "task-3",
        task_type: "mind_map.generate",
      },
    });
    expect(writes[1]).toMatchObject(
      createTaskErrorEvent(
        "task-3",
        "provider_unsupported",
        "Provider is not supported for the agent runtime",
        "Provider weird-provider is not supported for the agent runtime",
      ),
    );
  });
});
