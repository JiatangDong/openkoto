import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ArticleReader } from "./ArticleReader";
import type { Article } from "../../types";

const invokeMock = vi.fn();
const localStorageStore = new Map<string, string>();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
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

vi.mock("./ArticleMindMapPanel", () => ({
  ArticleMindMapPanel: () => <div data-testid="article-mind-map-panel" />,
}));

vi.mock("./VideoSubtitlePlayer", () => ({
  VideoSubtitlePlayer: () => <div data-testid="video-subtitle-player" />,
}));

function createArticle(overrides: Partial<Article> = {}): Article {
  return {
    id: "article-1",
    title: "Sample Article",
    content: "Alpha beta gamma.",
    created_at: "2026-03-08T00:00:00Z",
    translated: false,
    segments: [
      {
        id: "seg-1",
        article_id: "article-1",
        order: 0,
        text: "Alpha beta gamma.",
        created_at: "2026-03-08T00:00:00Z",
      },
    ],
    ...overrides,
  };
}

describe("ArticleReader agent mode", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    localStorageStore.clear();
    Object.defineProperty(window, "localStorage", {
      value: {
        getItem: (key: string) => localStorageStore.get(key) ?? null,
        setItem: (key: string, value: string) => {
          localStorageStore.set(key, value);
        },
        removeItem: (key: string) => {
          localStorageStore.delete(key);
        },
      },
      configurable: true,
    });
  });

  afterEach(() => {
    cleanup();
  });

  it("renders agent in the existing tab row without a separate top mode switch", async () => {
    render(<ArticleReader article={createArticle()} />);

    expect(screen.getByRole("button", { name: "讲解" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "对话" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Agent" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "快问" })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "Agent" }));

    expect(screen.getByText("当前支持")).toBeInTheDocument();
    expect(screen.getByText("查看当前素材")).toBeInTheDocument();
  });
});
