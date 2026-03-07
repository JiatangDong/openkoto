export interface WorkerTaskPayload {
  article_id: string;
  [key: string]: unknown;
}

export interface WorkerTaskStartParams {
  task_id: string;
  task_type: string;
  payload: WorkerTaskPayload;
}

export interface WorkerRequest {
  id: string;
  type: "request";
  method: string;
  params: WorkerTaskStartParams;
}

export interface WorkerProgressEvent {
  type: "event";
  event: "task.progress";
  payload: {
    task_id: string;
    stage: string;
    progress: number;
    message?: string;
  };
}

export interface WorkerHeartbeatEvent {
  type: "event";
  event: "worker.heartbeat";
  payload: {
    worker_session_id: string;
    timestamp: string;
  };
}

