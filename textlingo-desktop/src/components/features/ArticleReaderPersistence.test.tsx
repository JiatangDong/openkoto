import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ArticleReader } from "./ArticleReader";
import type { Article } from "../../types";
import { resetUiStateForTests } from "../../lib/uiState";

const invokeMock = vi.fn();
const localStorageStore = new Map<string, string>();

/** In-memory fake backend honoring get/set_ui_state merge semantics. */
let fakeBackend: Record<string, string> = {};

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  save: vi.fn(),
  open: vi.fn(),
}));

vi.mock("react-i18next", () => ({
  useTranslation: () => ({
    t: (key: string, fallbackOrOptions?: string | Record<string, unknown>) =>
      typeof fallbackOrOptions === "string" ? fallbackOrOptions : key,
  }),
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
        text: "Alpha",
        translation: "Beta",
        created_at: "2026-03-08T00:00:00Z",
      },
    ],
    ...overrides,
  };
}

describe("ArticleReader persistence", () => {
  beforeEach(() => {
    resetUiStateForTests();
    fakeBackend = {};
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
    invokeMock.mockImplementation((cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "get_ui_state") return Promise.resolve({ ...fakeBackend });
      if (cmd === "set_ui_state") {
        const updates = (args?.updates ?? {}) as Record<string, string>;
        Object.assign(fakeBackend, updates);
        return Promise.resolve({ ...fakeBackend });
      }
      if (cmd === "get_config") return Promise.resolve(null);
      return Promise.resolve(undefined);
    });
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("restores the translation view mode after unmount and remount", async () => {
    const { unmount } = render(<ArticleReader article={createArticle()} />);

    // Default is original: segment shows the source text.
    expect(screen.getByText("Alpha")).toBeInTheDocument();

    await userEvent.click(screen.getByTestId("reader-toolbar-view-mode-trigger"));
    await userEvent.click(
      screen.getByRole("menuitem", { name: "articleReader.viewMode.translation" }),
    );

    // Translation mode renders the translated text instead.
    expect(screen.getByText("Beta")).toBeInTheDocument();
    // Global only: no per-article keys may be written.
    expect(fakeBackend).toEqual({ textlingo_view_mode: "translation" });

    // Simulate leaving the page and coming back with cold caches: neither
    // the in-memory store nor localStorage may serve the value — the only
    // durable copy is the backend, and restoration is async (hydration).
    unmount();
    resetUiStateForTests();
    localStorageStore.clear();
    render(<ArticleReader article={createArticle()} />);

    expect(await screen.findByText("Beta")).toBeInTheDocument();
    expect(screen.queryByText("Alpha")).not.toBeInTheDocument();
  });

  it("restores the font size after unmount and remount", async () => {
    const { unmount } = render(<ArticleReader article={createArticle()} />);

    expect(screen.getByText("18")).toBeInTheDocument();

    await userEvent.click(screen.getByTitle("Increase font size"));

    expect(screen.getByText("20")).toBeInTheDocument();
    expect(fakeBackend["textlingo_font_size"]).toBe("20");

    // Cold caches again: proves the remount restores from the backend
    // (asynchronously) rather than from a leftover localStorage entry.
    unmount();
    resetUiStateForTests();
    localStorageStore.clear();
    render(<ArticleReader article={createArticle()} />);

    expect(await screen.findByText("20")).toBeInTheDocument();
  });

  it("shares view mode and font size across articles", async () => {
    const { unmount } = render(<ArticleReader article={createArticle()} />);

    await userEvent.click(screen.getByTestId("reader-toolbar-view-mode-trigger"));
    await userEvent.click(
      screen.getByRole("menuitem", { name: "articleReader.viewMode.translation" }),
    );
    await userEvent.click(screen.getByTitle("Increase font size"));
    unmount();

    // A different article immediately sees the same settings — no
    // per-article keys, no follow-up action required.
    render(<ArticleReader article={createArticle({ id: "article-2" })} />);

    expect(screen.getByText("Beta")).toBeInTheDocument();
    expect(screen.getByText("20")).toBeInTheDocument();
    expect(fakeBackend).toEqual({
      textlingo_view_mode: "translation",
      textlingo_font_size: "20",
    });
  });
});
