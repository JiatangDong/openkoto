import type {
  WorkerHeartbeatEvent,
  WorkerProgressEvent,
  WorkerRequest,
} from "./protocol";
import { parseMindMapResult } from "./mindMapSchema";
import { z } from "zod";

const workerRequestSchema = z.object({
  id: z.string().min(1),
  type: z.literal("request"),
  method: z.string().min(1),
  params: z.object({
    task_id: z.string().min(1),
    task_type: z.string().min(1),
    payload: z.object({
      article_id: z.string().min(1),
    }).passthrough(),
  }),
});

export function parseWorkerRequest(raw: string): WorkerRequest {
  return workerRequestSchema.parse(JSON.parse(raw)) as WorkerRequest;
}

export function createProgressEvent(
  taskId: string,
  stage: string,
  progress: number,
  message?: string,
): WorkerProgressEvent {
  return {
    type: "event",
    event: "task.progress",
    payload: {
      task_id: taskId,
      stage,
      progress,
      message,
    },
  };
}

export function createHeartbeatEvent(workerSessionId: string): WorkerHeartbeatEvent {
  return {
    type: "event",
    event: "worker.heartbeat",
    payload: {
      worker_session_id: workerSessionId,
      timestamp: new Date().toISOString(),
    },
  };
}

export function validateMindMapResult(value: unknown) {
  return parseMindMapResult(value);
}
