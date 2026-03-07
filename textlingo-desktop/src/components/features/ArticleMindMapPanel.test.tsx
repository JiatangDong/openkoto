import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ArticleReader } from "./ArticleReader";
import { ArticleMindMapPanel } from "./ArticleMindMapPanel";
import { AgentTask, Article, Artifact, MindMapResult } from "../../types";

const invokeMock = vi.fn();
const listenerMap = new Map<string, (event: { payload: unknown }) => void>();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (eventName: string, handler: (event: { payload: unknown }) => void) => {
    listenerMap.set(eventName, handler);
    return () => listenerMap.delete(eventName);
  }),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  save: vi.fn(),
}));

vi.mock("docx", () => ({
  Document: class {},
  HeadingLevel: {},
  Packer: { toBlob: vi.fn() },
  Paragraph: class {},
  TextRun: class {},
}));

vi.mock("../../lib/hooks", () => ({
  useConfig: () => ({
    config: {
      target_language: "zh-CN",
    },
  }),
}));

vi.mock("./ArticleChatAssistant", () => ({
  ArticleChatAssistant: () => <div data-testid="article-chat-assistant" />,
}));

vi.mock("./ArticleExplanationPanel", () => ({
  ArticleExplanationPanel: () => <div data-testid="article-explanation-panel" />,
}));

vi.mock("./VideoSubtitlePlayer", () => ({
  VideoSubtitlePlayer: () => <div data-testid="video-subtitle-player" />,
}));

function createArticle(overrides: Partial<Article> = {}): Article {
  return {
    id: "article-1",
    title: "Sample Article",
    content: "Alpha beta gamma. Delta epsilon zeta.",
    created_at: "2026-03-07T00:00:00Z",
    translated: false,
    segments: [
      {
        id: "seg-1",
        article_id: "article-1",
        order: 0,
        text: "Alpha beta gamma.",
        created_at: "2026-03-07T00:00:00Z",
      },
    ],
    ...overrides,
  };
}

function createTask(overrides: Partial<AgentTask> = {}): AgentTask {
  return {
    id: "task-1",
    task_type: "mind_map_generate",
    status: "queued",
    article_id: "article-1",
    input: {
      article_id: "article-1",
      display_language: "zh-CN",
      max_depth: 3,
      evidence_mode: "strict",
      prefer_structure: "topic_tree",
    },
    progress: 0,
    stage: "queued",
    artifact_ids: [],
    created_at: "2026-03-07T00:00:00Z",
    updated_at: "2026-03-07T00:00:00Z",
    ...overrides,
  };
}

function createMindMapResult(overrides: Partial<MindMapResult> = {}): MindMapResult {
  return {
    status: "applicable",
    reason: null,
    map: {
      version: "1",
      article_id: "article-1",
      title: "Sample Article",
      display_language: "zh-CN",
      generation_mode: "evidence_first",
      source_hash: "sha256:test",
      summary: "Summary",
      root: {
        id: "root",
        title: "Sample Article",
        node_type: "root",
        summary: "Summary",
        confidence: 0.9,
        source_segment_ids: ["seg-1"],
        source_offsets: [],
        children: [
          {
            id: "node-theme",
            title: "Core Theme",
            node_type: "theme",
            summary: "Theme summary",
            confidence: 0.8,
            source_segment_ids: ["seg-1"],
            source_offsets: [],
            children: [],
          },
        ],
      },
    },
    diagnostics: {
      content_type: "article",
      coverage: "full",
      notes: [],
      window_count: 1,
      evidence_density: 1,
      low_confidence_node_ids: [],
    },
    ...overrides,
  };
}

function createArtifact(result: MindMapResult): Artifact {
  return {
    id: "artifact-1",
    task_id: "task-1",
    article_id: "article-1",
    artifact_type: "mind_map",
    version: "1",
    content: result,
    created_at: "2026-03-07T00:00:00Z",
    updated_at: "2026-03-07T00:00:00Z",
  };
}

describe("ArticleMindMapPanel", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    listenerMap.clear();
  });

  afterEach(() => {
    cleanup();
  });

  it("renders the new mind map tab in the article reader", async () => {
    invokeMock.mockResolvedValue(null);

    render(<ArticleReader article={createArticle()} />);

    await userEvent.click(screen.getByRole("button", { name: "articleReader.mindMap" }));

    expect(screen.getByRole("button", { name: "Generate Mind Map" })).toBeInTheDocument();
  });

  it("shows a generate CTA before a task exists and starts a task on click", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "create_mind_map_task_cmd") {
        return Promise.resolve(createTask());
      }
      return Promise.resolve(null);
    });

    render(<ArticleMindMapPanel article={createArticle()} targetLanguage="zh-CN" />);

    await userEvent.click(screen.getByRole("button", { name: "Generate Mind Map" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "create_mind_map_task_cmd",
        expect.objectContaining({
          articleId: "article-1",
          displayLanguage: "zh-CN",
        }),
      );
    });
  });

  it("shows progress updates while generation is running", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "create_mind_map_task_cmd") {
        return Promise.resolve(createTask());
      }
      return Promise.resolve(null);
    });

    render(<ArticleMindMapPanel article={createArticle()} targetLanguage="zh-CN" />);

    await userEvent.click(screen.getByRole("button", { name: "Generate Mind Map" }));

    listenerMap.get("agent-task-updated")?.({
      payload: createTask({
        status: "running",
        stage: "reading",
        progress: 0.42,
        message: "Reading source windows",
      }),
    });

    expect(await screen.findByText("Reading source windows")).toBeInTheDocument();
    expect(screen.getByText("42%")).toBeInTheDocument();
  });

  it("renders a not-applicable empty state from the saved artifact", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "get_artifact_cmd") {
        return Promise.resolve(
          createArtifact(
            createMindMapResult({
              status: "not_applicable",
              reason: "music_only",
              map: null,
              diagnostics: {
                content_type: "music_only",
                coverage: "none",
                notes: ["No stable semantic content detected."],
                window_count: 1,
                evidence_density: 0,
                low_confidence_node_ids: [],
              },
            }),
          ),
        );
      }
      return Promise.resolve(null);
    });

    render(
      <ArticleMindMapPanel
        article={createArticle({ active_mind_map_artifact_id: "artifact-1" })}
        targetLanguage="zh-CN"
      />,
    );

    expect(await screen.findByText("Mind map unavailable")).toBeInTheDocument();
    expect(screen.getByText("No stable semantic content detected.")).toBeInTheDocument();
  });

  it("renders a successful tree result from the saved artifact", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "get_artifact_cmd") {
        return Promise.resolve(createArtifact(createMindMapResult({})));
      }
      return Promise.resolve(null);
    });

    render(
      <ArticleMindMapPanel
        article={createArticle({ active_mind_map_artifact_id: "artifact-1" })}
        targetLanguage="zh-CN"
      />,
    );

    expect(await screen.findByText("Core Theme")).toBeInTheDocument();
    expect(screen.getByText("Theme summary")).toBeInTheDocument();
  });
});
