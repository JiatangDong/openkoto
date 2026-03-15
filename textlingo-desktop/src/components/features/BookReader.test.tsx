import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { BookReader } from "./BookReader";
import { Article } from "../../types";

const invokeMock = vi.fn();
const localStorageStore = new Map<string, string>();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  save: vi.fn(),
}));

vi.mock("react-i18next", () => ({
  useTranslation: () => ({
    t: (_key: string, fallback?: string) => fallback ?? _key,
  }),
}));

vi.mock("../../lib/hooks", () => ({
  useConfig: () => ({
    config: {
      target_language: "zh-CN",
    },
  }),
}));

vi.mock("./TxtReader", () => ({
  TxtReader: () => <div data-testid="txt-reader">TXT Reader</div>,
}));

vi.mock("./PdfReader", () => ({
  PdfReader: () => <div data-testid="pdf-reader">PDF Reader</div>,
}));

vi.mock("./EpubReader", () => ({
  EpubReader: () => <div data-testid="epub-reader">EPUB Reader</div>,
}));

vi.mock("./ArticleChatAssistant", () => ({
  ArticleChatAssistant: () => <div data-testid="article-chat-assistant">Chat Assistant</div>,
}));

vi.mock("./ArticleMindMapPanel", () => ({
  ArticleMindMapPanel: ({ panelMode }: { panelMode?: string }) => (
    <div data-testid="article-mind-map-panel" data-panel-mode={panelMode ?? "unknown"}>
      Mind Map Panel
    </div>
  ),
}));

function createBookArticle(overrides: Partial<Article> = {}): Article {
  return {
    id: "book-1",
    title: "Book Title",
    content: "Book content",
    created_at: "2026-03-07T00:00:00Z",
    translated: false,
    book_type: "txt",
    book_path: "/tmp/book.txt",
    ...overrides,
  };
}

describe("BookReader", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    invokeMock.mockResolvedValue({});
    vi.stubGlobal("confirm", vi.fn(() => false));
    vi.stubGlobal("alert", vi.fn());
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

  it("renders mind map and chat tabs for books and defaults to the mind map", async () => {
    render(<BookReader article={createBookArticle()} />);

    expect(screen.getByRole("button", { name: "思维导图" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "对话" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "1/3" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "2/3" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "全屏" })).toBeInTheDocument();
    expect(screen.getByTestId("article-mind-map-panel")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "对话" }));
    expect(screen.getByTestId("article-chat-assistant")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "全屏" }));
    expect(screen.getByTestId("book-reader-shell")).toHaveAttribute("data-assistant-mode", "full");
    expect(screen.getByTestId("book-reader-main-pane")).toHaveAttribute("data-hidden", "true");
  });

  it("reuses the same assistant shell for pdf books", () => {
    render(<BookReader article={createBookArticle({ book_type: "pdf", book_path: "/tmp/book.pdf" })} />);

    expect(screen.getByTestId("book-reader-shell")).toBeInTheDocument();
    expect(screen.getByTestId("pdf-reader")).toBeInTheDocument();
    expect(screen.getByTestId("article-mind-map-panel")).toBeInTheDocument();
  });

  it("starts pdf translation without plugin install gating", async () => {
    invokeMock.mockImplementation(async (command: string) => {
      if (command === "check_pdf_translation_files") {
        return {};
      }
      if (command === "get_config") {
        return {
          target_language: "zh-CN",
          active_model_id: "model-1",
          model_configs: [
            {
              id: "model-1",
              api_provider: "openai",
              api_key: "secret",
              model: "gpt-4o-mini",
            },
          ],
        };
      }
      if (command === "translate_pdf_document") {
        return {
          success: true,
          mono_pdf: "/tmp/book-mono.pdf",
          dual_pdf: "/tmp/book-dual.pdf",
          original_pdf: "/tmp/book.pdf",
        };
      }

      return {};
    });

    render(<BookReader article={createBookArticle({ book_type: "pdf", book_path: "/tmp/book.pdf" })} />);

    await userEvent.click(screen.getByRole("button", { name: "翻译全文" }));

    expect(invokeMock.mock.calls.some(([command]) => command === "check_plugin_installed_cmd")).toBe(false);
    expect(invokeMock).toHaveBeenCalledWith("translate_pdf_document", {
      pdfPath: "/tmp/book.pdf",
      langIn: "auto",
      langOut: "zh-CN",
      provider: "openai",
      apiKey: "secret",
      model: "gpt-4o-mini",
      baseUrl: undefined,
    });
  });
});
