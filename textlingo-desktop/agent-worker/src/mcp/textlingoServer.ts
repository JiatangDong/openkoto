import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const ALLOWED_TOOL_NAMES = [
  "mcp__textlingo__article_get_overview",
  "mcp__textlingo__article_read_window",
  "mcp__textlingo__article_search",
  "mcp__textlingo__article_get_evidence",
  "mcp__textlingo__task_report_progress",
  "mcp__textlingo__artifact_save",
] as const;

export interface TextlingoToolAdapters {
  articleGetOverview(args: { article_id: string }): Promise<unknown>;
  articleReadWindow(args: {
    article_id: string;
    cursor: number;
    max_chars: number;
  }): Promise<unknown>;
  articleSearch(args: {
    article_id: string;
    query: string;
    limit?: number;
  }): Promise<unknown>;
  articleGetEvidence(args: {
    article_id: string;
    segment_ids: string[];
  }): Promise<unknown>;
  taskReportProgress(args: {
    task_id: string;
    stage: string;
    progress: number;
    message?: string;
  }): Promise<unknown>;
  artifactSave(args: {
    task_id: string;
    article_id: string;
    content: unknown;
  }): Promise<unknown>;
}

function jsonResult(payload: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(payload),
      },
    ],
  };
}

export function getTextlingoAllowedToolNames(): string[] {
  return [...ALLOWED_TOOL_NAMES];
}

export function createTextlingoSdkServer(adapters: TextlingoToolAdapters) {
  return createSdkMcpServer({
    name: "textlingo",
    tools: [
      tool(
        "article_get_overview",
        "Get article-level metadata for planning a mind map task.",
        { article_id: z.string().min(1) },
        async (args) => jsonResult(await adapters.articleGetOverview(args)),
      ),
      tool(
        "article_read_window",
        "Read a source text window from the article.",
        {
          article_id: z.string().min(1),
          cursor: z.number().int().nonnegative(),
          max_chars: z.number().int().positive(),
        },
        async (args) => jsonResult(await adapters.articleReadWindow(args)),
      ),
      tool(
        "article_search",
        "Search article segments by query.",
        {
          article_id: z.string().min(1),
          query: z.string().min(1),
          limit: z.number().int().positive().optional(),
        },
        async (args) => jsonResult(await adapters.articleSearch(args)),
      ),
      tool(
        "article_get_evidence",
        "Fetch evidence items by segment id.",
        {
          article_id: z.string().min(1),
          segment_ids: z.array(z.string().min(1)).min(1),
        },
        async (args) => jsonResult(await adapters.articleGetEvidence(args)),
      ),
      tool(
        "task_report_progress",
        "Report task progress back to the desktop app.",
        {
          task_id: z.string().min(1),
          stage: z.string().min(1),
          progress: z.number().min(0).max(1),
          message: z.string().optional(),
        },
        async (args) => jsonResult(await adapters.taskReportProgress(args)),
      ),
      tool(
        "artifact_save",
        "Save the final mind map artifact.",
        {
          task_id: z.string().min(1),
          article_id: z.string().min(1),
          content: z.unknown(),
        },
        async (args) => jsonResult(await adapters.artifactSave(args)),
      ),
    ],
  });
}

