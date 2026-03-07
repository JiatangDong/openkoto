import { z } from "zod";

import type {
  WorkerHeartbeatEvent,
  WorkerProgressEvent,
  WorkerRequest,
} from "./protocol";

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

const mindMapNodeSchema: z.ZodType<any> = z.lazy(() =>
  z.object({
    id: z.string().min(1),
    title: z.string().min(1),
    node_type: z.string().min(1),
    summary: z.string(),
    confidence: z.number().min(0).max(1),
    source_segment_ids: z.array(z.string()).default([]),
    source_offsets: z
      .array(
        z.object({
          start: z.number().int().nonnegative(),
          end: z.number().int().nonnegative(),
        }),
      )
      .default([]),
    time_range: z
      .object({
        start: z.number(),
        end: z.number(),
      })
      .optional(),
    children: z.array(mindMapNodeSchema).default([]),
  }),
);

const mindMapResultSchema = z
  .object({
    status: z.enum(["applicable", "partial", "not_applicable"]),
    reason: z.string().nullable().optional(),
    map: z
      .object({
        version: z.string().min(1),
        article_id: z.string().min(1),
        title: z.string().min(1),
        display_language: z.string().min(1),
        generation_mode: z.string().min(1),
        source_hash: z.string().min(1),
        summary: z.string(),
        root: mindMapNodeSchema,
      })
      .nullable()
      .optional(),
    diagnostics: z.object({
      content_type: z.string().min(1),
      coverage: z.string().min(1),
      notes: z.array(z.string()).default([]),
      window_count: z.number().int().nonnegative(),
      evidence_density: z.number().min(0).max(1),
      low_confidence_node_ids: z.array(z.string()).default([]),
    }),
  })
  .superRefine((value, ctx) => {
    if ((value.status === "applicable" || value.status === "partial") && !value.map) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "map is required when status is applicable or partial",
        path: ["map"],
      });
    }
    if (value.status === "not_applicable" && value.map) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "map must be null when status is not_applicable",
        path: ["map"],
      });
    }
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
  return mindMapResultSchema.parse(value);
}

