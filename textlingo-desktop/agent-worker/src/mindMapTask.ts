import { query } from "@anthropic-ai/claude-agent-sdk";
import type { McpServerConfig, Options, SettingSource } from "@anthropic-ai/claude-agent-sdk";

import { parseMindMapResult } from "./mindMapSchema";
import {
  createTextlingoSdkServer,
  getTextlingoAllowedToolNames,
} from "./mcp/textlingoServer";

const DISALLOWED_TOOLS = ["Read", "Write", "Edit", "Bash", "WebFetch", "WebSearch"];

const MIND_MAP_OUTPUT_SCHEMA = {
  type: "object",
  required: ["status", "diagnostics"],
  properties: {
    status: {
      type: "string",
      enum: ["applicable", "partial", "not_applicable"],
    },
    reason: {
      type: ["string", "null"],
    },
    map: {
      type: ["object", "null"],
    },
    diagnostics: {
      type: "object",
    },
  },
} as const;

export interface MindMapTaskInput {
  taskId: string;
  articleId: string;
  displayLanguage: string;
}

export interface MindMapTaskDeps {
  sdkQuery?: (params: { prompt: string; options: ReturnType<typeof buildMindMapQueryOptions> }) => AsyncIterable<unknown>;
  saveArtifact(taskId: string, artifactType: "mind_map", content: unknown): Promise<{ artifact_id: string }>;
  reportProgress(taskId: string, stage: string, progress: number, message?: string): Promise<void>;
  cwd: string;
  model: string;
  pathToClaudeCodeExecutable?: string;
  mcpServer: McpServerConfig;
}

export function buildMindMapQueryOptions(input: {
  cwd: string;
  model: string;
  pathToClaudeCodeExecutable?: string;
  mcpServer: McpServerConfig;
}): Options {
  const settingSources: SettingSource[] = ["project"];
  return {
    cwd: input.cwd,
    model: input.model,
    pathToClaudeCodeExecutable: input.pathToClaudeCodeExecutable,
    settingSources,
    allowedTools: ["Skill", ...getTextlingoAllowedToolNames()],
    disallowedTools: DISALLOWED_TOOLS,
    mcpServers: {
      textlingo: input.mcpServer,
    },
    outputFormat: {
      type: "json_schema" as const,
      schema: MIND_MAP_OUTPUT_SCHEMA,
    },
  };
}

function buildMindMapPrompt(input: MindMapTaskInput) {
  return [
    "Use the generate-mindmap skill.",
    `Task ID: ${input.taskId}`,
    `Article ID: ${input.articleId}`,
    `Display language: ${input.displayLanguage}`,
    "Return only schema-valid mind map JSON.",
  ].join("\n");
}

export async function runMindMapTask(input: MindMapTaskInput, deps: MindMapTaskDeps) {
  await deps.reportProgress(input.taskId, "planning", 0.1, "Preparing mind map task");

  const prompt = buildMindMapPrompt(input);
  const options = buildMindMapQueryOptions({
    cwd: deps.cwd,
    model: deps.model,
    pathToClaudeCodeExecutable: deps.pathToClaudeCodeExecutable,
    mcpServer: deps.mcpServer,
  });

  const sdkQuery = deps.sdkQuery ?? query;
  let lastResult: unknown = null;

  for await (const message of sdkQuery({ prompt, options })) {
    if (
      message &&
      typeof message === "object" &&
      "type" in message &&
      message.type === "result" &&
      "result" in message
    ) {
      lastResult = message.result;
    }
  }

  const parsed = parseMindMapResult(lastResult);
  await deps.reportProgress(input.taskId, "saving", 0.9, "Saving mind map artifact");
  const artifact = await deps.saveArtifact(input.taskId, "mind_map", parsed);
  await deps.reportProgress(input.taskId, "done", 1, "Mind map generated");

  return artifact;
}

export function createDefaultTextlingoServer() {
  return createTextlingoSdkServer({
    async articleGetOverview() {
      throw new Error("articleGetOverview adapter not configured");
    },
    async articleReadWindow() {
      throw new Error("articleReadWindow adapter not configured");
    },
    async articleSearch() {
      throw new Error("articleSearch adapter not configured");
    },
    async articleGetEvidence() {
      throw new Error("articleGetEvidence adapter not configured");
    },
    async taskReportProgress() {
      throw new Error("taskReportProgress adapter not configured");
    },
    async artifactSave() {
      throw new Error("artifactSave adapter not configured");
    },
  });
}
