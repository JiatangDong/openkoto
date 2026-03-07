import type {
  WorkerErrorEvent,
  WorkerHeartbeatEvent,
  WorkerProgressEvent,
  WorkerRequest,
  WorkerResultEvent,
} from "./protocol.js";
import { runMindMapTask } from "./mindMapTask.js";
import { parseMindMapResult } from "./mindMapSchema.js";
import type { McpServerConfig } from "@anthropic-ai/claude-agent-sdk";
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

export function createResultEvent(taskId: string, content: unknown): WorkerResultEvent {
  return {
    type: "event",
    event: "task.result",
    payload: {
      task_id: taskId,
      content,
    },
  };
}

export function createErrorEvent(taskId: string, message: string): WorkerErrorEvent {
  return {
    type: "event",
    event: "task.error",
    payload: {
      task_id: taskId,
      message,
    },
  };
}

export function validateMindMapResult(value: unknown) {
  return parseMindMapResult(value);
}

export async function handleTaskRequest(
  request: WorkerRequest,
  deps: {
    runMindMapTask?: typeof runMindMapTask;
    saveArtifact: (taskId: string, artifactType: "mind_map", content: unknown) => Promise<{ artifact_id: string }>;
    reportProgress: (taskId: string, stage: string, progress: number, message?: string) => Promise<void>;
    cwd: string;
    model: string;
    pathToClaudeCodeExecutable?: string;
    mcpServer: McpServerConfig;
  },
) {
  if (request.method !== "task.start" || request.params.task_type !== "mind_map.generate") {
    throw new Error(`Unsupported task method: ${request.method}`);
  }

  const runner = deps.runMindMapTask ?? runMindMapTask;
  return runner(
    {
      taskId: request.params.task_id,
      articleId: request.params.payload.article_id,
      displayLanguage:
        typeof request.params.payload.display_language === "string"
          ? request.params.payload.display_language
          : "zh-CN",
    },
    {
      saveArtifact: deps.saveArtifact,
      reportProgress: deps.reportProgress,
      cwd: deps.cwd,
      model: deps.model,
      pathToClaudeCodeExecutable: deps.pathToClaudeCodeExecutable,
      mcpServer: deps.mcpServer,
    },
  );
}
