import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { vi, afterEach, beforeEach, describe, expect, it } from "vitest";
import { FavoritesPage } from "./FavoritesPage";

const invokeMock = vi.fn();
const saveMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  save: (...args: unknown[]) => saveMock(...args),
}));

function mockFavoritesData() {
  invokeMock.mockImplementation((command: string, payload?: Record<string, unknown>) => {
    if (command === "list_favorite_vocabularies_cmd") {
      return Promise.resolve([
        {
          id: "v1",
          word: "abandon",
          meaning: "放弃",
          usage: "v.",
          pack_ids: ["p1", "system-ungrouped"],
          srs_state: "new",
          due_date: "2026-02-16",
          review_count: 0,
          created_at: "2026-02-16T00:00:00Z",
        },
      ]);
    }
    if (command === "list_favorite_grammars_cmd") {
      return Promise.resolve([]);
    }
    if (command === "list_word_packs_cmd") {
      return Promise.resolve([
        { id: "system-ungrouped", name: "未分组", is_system: true },
        { id: "p1", name: payload?.name ?? "TOEFL", is_system: false },
      ]);
    }
    if (command === "create_word_pack_cmd") {
      return Promise.resolve({
        id: "p1",
        name: payload?.name ?? "TOEFL",
        is_system: false,
      });
    }
    if (command === "export_word_pack_cmd") {
      return Promise.resolve({
        file_name: payload?.packId === "all" ? "全部单词.okpack.json" : "TOEFL.okpack.json",
        json_content: "{\"schema_version\":\"openkoto-word-pack-v1\"}",
      });
    }
    if (command === "write_text_file") {
      return Promise.resolve(null);
    }
    if (command === "delete_word_pack_cmd") {
      return Promise.resolve(null);
    }
    if (command === "get_article") {
      return Promise.resolve({
        id: payload?.id ?? "a1",
        title: "Source Article",
        content: "content",
        created_at: "2026-02-16T00:00:00Z",
        updated_at: "2026-02-16T00:00:00Z",
      });
    }
    if (command === "import_word_pack_cmd") {
      return Promise.resolve({
        created_pack_id: "p2",
        total: 1,
        imported: 1,
        skipped: 0,
        errors: [],
      });
    }
    return Promise.resolve(null);
  });
}

describe("FavoritesPage", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    saveMock.mockReset();
    saveMock.mockResolvedValue("/tmp/export.okpack.json");
    vi.restoreAllMocks();
    Object.assign(navigator, {
      clipboard: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
    });
  });

  afterEach(() => {
    cleanup();
  });

  it("renders vocabulary list grouped with packs", async () => {
    mockFavoritesData();

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("abandon");
    expect(screen.getByText("TOEFL")).toBeInTheDocument();
    expect(screen.getByText("单词合集")).toBeInTheDocument();
  });

  it("creates a pack from the new-pack dialog", async () => {
    mockFavoritesData();

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("单词合集");
    const newButtons = screen.getAllByRole("button", { name: "新建" });
    await userEvent.click(newButtons[newButtons.length - 1]);

    const nameInput = await screen.findByPlaceholderText("输入新合集名称");
    await userEvent.type(nameInput, "TOEFL");
    await userEvent.click(screen.getByRole("button", { name: "创建" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "create_word_pack_cmd",
        expect.objectContaining({ name: "TOEFL" })
      );
    });
  });

  it("replaces the top-right management control with an import button", async () => {
    mockFavoritesData();

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findAllByText("abandon");
    expect(screen.getAllByRole("button", { name: "导入单词包" }).length).toBeGreaterThan(0);
    expect(screen.queryByRole("button", { name: "管理" })).not.toBeInTheDocument();
  });

  it("shows export-list actions from the all-words row menu", async () => {
    mockFavoritesData();

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findAllByText("abandon");
    await userEvent.click(screen.getByRole("button", { name: "全部单词操作" }));

    expect(await screen.findByRole("menuitem", { name: "复制到剪贴板" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "下载 TXT 文件" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "导出单词包" })).toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "删除合集" })).not.toBeInTheDocument();
  });

  it("shows pack-specific actions from row menus", async () => {
    mockFavoritesData();

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findAllByText("abandon");

    await userEvent.click(screen.getByRole("button", { name: "未分组操作" }));
    expect(await screen.findByRole("menuitem", { name: "导出单词包" })).toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "删除合集" })).not.toBeInTheDocument();

    await userEvent.keyboard("{Escape}");
    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    expect(await screen.findByRole("menuitem", { name: "导出单词包" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "删除合集" })).toBeInTheDocument();
  });

  it("exports all words as a synthetic word pack", async () => {
    mockFavoritesData();
    const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {});

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findAllByText("abandon");
    await userEvent.click(screen.getByRole("button", { name: "全部单词操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "导出单词包" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("export_word_pack_cmd", { packId: "all" });
    });
    expect(saveMock).toHaveBeenCalledWith(
      expect.objectContaining({ defaultPath: "全部单词.okpack.json" })
    );
    expect(alertSpy).not.toHaveBeenCalled();

    alertSpy.mockRestore();
  });

  it("supports copy, txt download, article navigation, back, and pack deletion", async () => {
    const onBack = vi.fn();
    const onSelectArticle = vi.fn();
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    mockFavoritesData();

    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([
          {
            id: "v1",
            word: "abandon",
            meaning: "放弃",
            usage: "v.",
            explanation: "example",
            source_article_id: "a1",
            source_article_title: "Source Article",
            pack_ids: ["p1"],
            srs_state: "new",
            due_date: "2026-02-16",
            review_count: 0,
            created_at: "2026-02-16T00:00:00Z",
          },
        ]);
      }
      if (command === "list_favorite_grammars_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_word_packs_cmd") {
        return Promise.resolve([{ id: "p1", name: "TOEFL", is_system: false }]);
      }
      if (command === "get_article") {
        return Promise.resolve({
          id: "a1",
          title: "Source Article",
          content: "content",
          created_at: "2026-02-16T00:00:00Z",
          updated_at: "2026-02-16T00:00:00Z",
        });
      }
      if (command === "export_word_pack_cmd") {
        return Promise.resolve({
          file_name: "TOEFL.okpack.json",
          json_content: "{\"schema_version\":\"openkoto-word-pack-v1\"}",
        });
      }
      if (command === "write_text_file" || command === "delete_word_pack_cmd") {
        return Promise.resolve(null);
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={onBack} onSelectArticle={onSelectArticle} />);

    await screen.findByText("abandon");
    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "复制到剪贴板" }));
    await waitFor(() => {
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith("abandon");
    });

    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "下载 TXT 文件" }));
    await waitFor(() => {
      expect(saveMock).toHaveBeenCalledWith(expect.objectContaining({ defaultPath: "TOEFL.txt" }));
    });

    await userEvent.click(screen.getByTitle("Source Article"));
    expect(onSelectArticle).toHaveBeenCalledWith(expect.objectContaining({ id: "a1" }));

    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "删除合集" }));
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("delete_word_pack_cmd", { id: "p1" });
    });

    await userEvent.click(screen.getAllByRole("button")[0]);
    expect(onBack).toHaveBeenCalled();
    confirmSpy.mockRestore();
  });

  it("imports a word pack from the hidden file input", async () => {
    mockFavoritesData();
    const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {});

    class MockFileReader {
      onload: ((event: { target: { result: string } }) => void) | null = null;

      readAsText() {
        this.onload?.({ target: { result: "{\"schema_version\":\"openkoto-word-pack-v1\"}" } });
      }
    }

    vi.stubGlobal("FileReader", MockFileReader);

    const { container } = render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("abandon");
    const input = container.querySelector('input[type="file"]');
    expect(input).not.toBeNull();

    fireEvent.change(input as Element, {
      target: {
        files: [new File(["{}"], "all.okpack.json", { type: "application/json" })],
      },
    });

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("import_word_pack_cmd", {
        jsonContent: "{\"schema_version\":\"openkoto-word-pack-v1\"}",
      });
    });
    expect(alertSpy).toHaveBeenCalled();
    alertSpy.mockRestore();
  });
});
