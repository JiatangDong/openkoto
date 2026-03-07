import { describe, expect, it } from "vitest";

import {
  createErrorEvent,
  createHeartbeatEvent,
  createProgressEvent,
  createResultEvent,
  parseWorkerRequest,
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
});
