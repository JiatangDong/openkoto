import { describe, expect, it, vi } from "vitest";

import {
  buildMindMapQueryOptions,
  runMindMapTask,
} from "./mindMapTask.js";
import { getTextlingoAllowedToolNames } from "./mcp/textlingoServer.js";

describe("mindMapTask", () => {
  it("builds Claude SDK options with project skills and controlled tools", () => {
    const options = buildMindMapQueryOptions({
      cwd: "/tmp/agent-worker",
      model: "claude-sonnet-4-5-20250929",
      pathToClaudeCodeExecutable: "/tmp/bin/claude",
      mcpServer: { type: "stdio", name: "textlingo" } as any,
    });

    expect(options.cwd).toBe("/tmp/agent-worker");
    expect(options.model).toBe("claude-sonnet-4-5-20250929");
    expect(options.pathToClaudeCodeExecutable).toBe("/tmp/bin/claude");
    expect(options.settingSources).toEqual(["project"]);
    expect(options.allowedTools).toContain("Skill");
    expect(options.allowedTools).toEqual(
      expect.arrayContaining(getTextlingoAllowedToolNames()),
    );
    expect(options.disallowedTools).toEqual(
      expect.arrayContaining(["Read", "Write", "Edit", "Bash", "WebFetch", "WebSearch"]),
    );
    expect(options.mcpServers?.textlingo).toBeDefined();
  });

  it("parses a successful result and saves it as an artifact", async () => {
    const saveArtifact = vi.fn(async () => ({ artifact_id: "artifact-1" }));
    const reportProgress = vi.fn(async () => undefined);
    const sdkQuery = vi.fn(async function* () {
      yield {
        type: "result",
        result: {
          status: "applicable",
          reason: null,
          map: {
            version: "1",
            article_id: "article-1",
            title: "Sample",
            display_language: "zh-CN",
            generation_mode: "evidence_first",
            source_hash: "sha256:abc",
            summary: "Overview",
            root: {
              id: "root",
              title: "Root",
              node_type: "root",
              summary: "Summary",
              confidence: 0.9,
              source_segment_ids: ["seg-1"],
              source_offsets: [],
              children: [],
            },
          },
          diagnostics: {
            content_type: "narrative",
            coverage: "full",
            notes: [],
            window_count: 1,
            evidence_density: 1,
            low_confidence_node_ids: [],
          },
        },
      };
    });

    const result = await runMindMapTask(
      {
        taskId: "task-1",
        articleId: "article-1",
        displayLanguage: "zh-CN",
      },
      {
        sdkQuery,
        saveArtifact,
        reportProgress,
        cwd: "/tmp/agent-worker",
        model: "claude-sonnet-4-5-20250929",
        pathToClaudeCodeExecutable: "/tmp/bin/claude",
        mcpServer: { type: "stdio", name: "textlingo" } as any,
      },
    );

    expect(sdkQuery).toHaveBeenCalledTimes(1);
    expect(saveArtifact).toHaveBeenCalledWith(
      "task-1",
      "mind_map",
      expect.objectContaining({ status: "applicable" }),
    );
    expect(reportProgress).toHaveBeenCalled();
    expect(result.artifact_id).toBe("artifact-1");
  });
});
