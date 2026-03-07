import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

import { createTextlingoSdkServer } from "./mcp/textlingoServer.js";
import {
  createErrorEvent,
  createHeartbeatEvent,
  createProgressEvent,
  createResultEvent,
  handleTaskRequest,
  parseWorkerRequest,
} from "./runtime.js";

interface WorkerArticleSegment {
  id: string;
  text: string;
  start_time?: number;
  end_time?: number;
}

interface WorkerArticle {
  id: string;
  title: string;
  content: string;
  source_type?: string;
  book_type?: string;
  segments?: WorkerArticleSegment[];
}

function writeEvent(event: unknown) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function buildOverview(article: WorkerArticle) {
  return {
    article_id: article.id,
    title: article.title,
    source_type: article.source_type ?? "article",
    content_length: article.content.length,
    segment_count: article.segments?.length ?? 0,
    has_timestamps: (article.segments ?? []).some(
      (segment) => typeof segment.start_time === "number" && typeof segment.end_time === "number",
    ),
    has_segments: (article.segments?.length ?? 0) > 0,
    language_hint: "unknown",
    book_type: article.book_type ?? null,
  };
}

function readWindow(article: WorkerArticle, cursor: number, maxChars: number) {
  const safeCursor = Math.min(cursor, article.content.length);
  const requestedEnd = Math.min(article.content.length, safeCursor + maxChars);
  const nextCursor = requestedEnd;
  const text = article.content.slice(safeCursor, requestedEnd);
  const sourceSegmentIds = (article.segments ?? [])
    .filter((segment) => text.includes(segment.text))
    .map((segment) => segment.id);
  const matchingSegments = (article.segments ?? []).filter((segment) =>
    sourceSegmentIds.includes(segment.id),
  );
  const startTimes = matchingSegments
    .map((segment) => segment.start_time)
    .filter((value): value is number => typeof value === "number");
  const endTimes = matchingSegments
    .map((segment) => segment.end_time)
    .filter((value): value is number => typeof value === "number");

  return {
    cursor: safeCursor,
    next_cursor: nextCursor,
    has_more: requestedEnd < article.content.length,
    text,
    start_offset: safeCursor,
    end_offset: requestedEnd,
    source_segment_ids: sourceSegmentIds,
    time_range:
      startTimes.length && endTimes.length
        ? {
            start: Math.min(...startTimes),
            end: Math.max(...endTimes),
          }
        : null,
  };
}

function searchArticle(article: WorkerArticle, query: string, limit = 8) {
  const normalized = query.trim().toLowerCase();
  if (!normalized) {
    return { results: [] };
  }

  const results = (article.segments ?? [])
    .filter((segment) => segment.text.toLowerCase().includes(normalized))
    .slice(0, limit)
    .map((segment) => ({
      segment_id: segment.id,
      text: segment.text,
      score: normalized.length / Math.max(segment.text.length, 1),
      start_time: segment.start_time ?? null,
      end_time: segment.end_time ?? null,
    }));

  return { results };
}

function getEvidence(article: WorkerArticle, segmentIds: string[]) {
  const wanted = new Set(segmentIds);
  return {
    items: (article.segments ?? [])
      .filter((segment) => wanted.has(segment.id))
      .map((segment) => ({
        segment_id: segment.id,
        text: segment.text,
        start_time: segment.start_time ?? null,
        end_time: segment.end_time ?? null,
      })),
  };
}

function buildMockMindMap(article: WorkerArticle, displayLanguage: string) {
  if (!article.content.trim()) {
    return {
      status: "not_applicable",
      reason: "empty_transcript",
      map: null,
      diagnostics: {
        content_type: "unknown",
        coverage: "none",
        notes: ["No source text available."],
        window_count: 0,
        evidence_density: 0,
        low_confidence_node_ids: [],
      },
    };
  }

  const evidenceIds = (article.segments ?? []).slice(0, 3).map((segment) => segment.id);
  return {
    status: "partial",
    reason: "too_long_partial_only",
    map: {
      version: "1",
      article_id: article.id,
      title: article.title,
      display_language: displayLanguage,
      generation_mode: "mock",
      source_hash: `mock:${article.id}:${article.content.length}`,
      summary: article.content.slice(0, 120),
      root: {
        id: "root",
        title: article.title,
        node_type: "root",
        summary: article.content.slice(0, 120),
        confidence: 0.72,
        source_segment_ids: evidenceIds,
        source_offsets: [
          {
            start: 0,
            end: Math.min(article.content.length, 120),
          },
        ],
        children: [],
      },
    },
    diagnostics: {
      content_type: "article",
      coverage: "partial",
      notes: ["Mock runtime result"],
      window_count: 1,
      evidence_density: evidenceIds.length > 0 ? 1 : 0,
      low_confidence_node_ids: [],
    },
  };
}

async function processTaskLine(workerSessionId: string, rawLine: string) {
  if (!rawLine.trim()) {
    return;
  }

  const request = parseWorkerRequest(rawLine);
  const article = request.params.payload.article as WorkerArticle | undefined;
  if (!article) {
    throw new Error("Task payload is missing article content");
  }

  const reportProgress = async (
    taskId: string,
    stage: string,
    progress: number,
    message?: string,
  ) => {
    writeEvent(createProgressEvent(taskId, stage, progress, message));
  };

  const saveArtifact = async (taskId: string, _artifactType: "mind_map", content: unknown) => {
    writeEvent(createResultEvent(taskId, content));
    return { artifact_id: `artifact-${taskId}` };
  };

  const mcpServer = createTextlingoSdkServer({
    async articleGetOverview(args) {
      return buildOverview(article);
    },
    async articleReadWindow(args) {
      return readWindow(article, args.cursor, args.max_chars);
    },
    async articleSearch(args) {
      return searchArticle(article, args.query, args.limit);
    },
    async articleGetEvidence(args) {
      return getEvidence(article, args.segment_ids);
    },
    async taskReportProgress(args) {
      await reportProgress(args.task_id, args.stage, args.progress, args.message);
      return { ok: true };
    },
    async artifactSave(args) {
      return saveArtifact(args.task_id, "mind_map", args.content);
    },
  });

  const useMockRuntime =
    process.env.TEXTLINGO_AGENT_WORKER_USE_MOCK === "1" ||
    process.env.TEXTLINGO_AGENT_WORKER_USE_MOCK === "true";

  if (useMockRuntime) {
    await reportProgress(request.params.task_id, "planning", 0.1, "Preparing mind map task");
    await saveArtifact(
      request.params.task_id,
      "mind_map",
      buildMockMindMap(
        article,
        typeof request.params.payload.display_language === "string"
          ? request.params.payload.display_language
          : "zh-CN",
      ),
    );
    await reportProgress(request.params.task_id, "done", 1, "Mind map generated");
    return;
  }

  await handleTaskRequest(request, {
    saveArtifact,
    reportProgress,
    cwd: process.cwd(),
    model: process.env.TEXTLINGO_AGENT_MODEL ?? "claude-sonnet-4-5",
    pathToClaudeCodeExecutable: process.env.TEXTLINGO_CLAUDE_CODE_PATH,
    mcpServer,
  });

  writeEvent(createHeartbeatEvent(workerSessionId));
}

async function main() {
  const workerSessionId = randomUUID();
  writeEvent(createHeartbeatEvent(workerSessionId));

  const heartbeatTimer = setInterval(() => {
    writeEvent(createHeartbeatEvent(workerSessionId));
  }, 15_000);

  const rl = createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  rl.on("line", (line) => {
    void processTaskLine(workerSessionId, line).catch((error) => {
      let taskId = "unknown-task";
      try {
        taskId = parseWorkerRequest(line).params.task_id;
      } catch {
        // Ignore parse failures here; the original error is more useful.
      }
      writeEvent(createErrorEvent(taskId, error instanceof Error ? error.message : String(error)));
    });
  });

  rl.on("close", () => {
    clearInterval(heartbeatTimer);
    process.exit(0);
  });
}

void main();
