import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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
    vi.restoreAllMocks();
    // restoreAllMocks 会清掉 vi.fn() 的实现，必须在它之后再设置默认返回值
    saveMock.mockResolvedValue("/tmp/export.okpack.json");
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

  it("shows an import error alert when the pack import fails", async () => {
    mockFavoritesData();
    const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {});
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_favorite_grammars_cmd" || command === "list_word_packs_cmd") {
        return Promise.resolve([]);
      }
      if (command === "import_word_pack_cmd") {
        return Promise.reject("boom: invalid pack");
      }
      return Promise.resolve(null);
    });

    class MockFileReader {
      onload: ((event: { target: { result: string } }) => void) | null = null;

      readAsText() {
        this.onload?.({ target: { result: "{}" } });
      }
    }

    vi.stubGlobal("FileReader", MockFileReader);

    const { container } = render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("list_favorite_vocabularies_cmd");
    });
    fireEvent.change(container.querySelector('input[type="file"]') as Element, {
      target: {
        files: [new File(["{}"], "broken.okpack.json", { type: "application/json" })],
      },
    });

    await waitFor(() => {
      expect(alertSpy).toHaveBeenCalled();
    });
    const alertArg = alertSpy.mock.calls[0][0];
    expect(String(alertArg)).toContain("导入失败");
    alertSpy.mockRestore();
  });

  it("renders the review stats bar and filters vocabulary through search", async () => {
    mockFavoritesData();
    invokeMock.mockImplementation((command: string) => {
      if (command === "get_review_stats_cmd") {
        return Promise.resolve({
          streak_days: 3,
          new_today: 1,
          review_today: 2,
          total: 10,
          count_new: 4,
          count_learning: 3,
          count_review: 2,
          count_suspended: 1,
        });
      }
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([
          {
            id: "v1",
            word: "abandon",
            meaning: "放弃",
            usage: "v.",
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
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    expect(invokeMock).toHaveBeenCalledWith(
      "get_review_stats_cmd",
      expect.objectContaining({ packId: "all" })
    );
    await screen.findByText("连续打卡 {{count}} 天");
    expect(screen.getByText("今日:新词 {{new}} · 复习 {{review}}")).toBeInTheDocument();
    expect(screen.getByText("共 {{count}} 词")).toBeInTheDocument();
    expect(screen.getByText("abandon")).toBeInTheDocument();

    await userEvent.type(screen.getByPlaceholderText("搜索单词、释义或读音"), "zzz");
    expect(screen.queryByText("abandon")).not.toBeInTheDocument();
    expect(screen.getByText("暂无单词收藏")).toBeInTheDocument();

    await userEvent.clear(screen.getByPlaceholderText("搜索单词、释义或读音"));
    await userEvent.type(screen.getByPlaceholderText("搜索单词、释义或读音"), "ABANDON");
    expect(screen.getByText("abandon")).toBeInTheDocument();
  });

  it("deletes and suspends a vocabulary from its card", async () => {
    mockFavoritesData();
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([
          {
            id: "v1",
            word: "abandon",
            meaning: "放弃",
            usage: "v.",
            pack_ids: ["p1"],
            srs_state: "new",
            due_date: "2026-02-16",
            review_count: 0,
            created_at: "2026-02-16T00:00:00Z",
          },
        ]);
      }
      if (command === "list_favorite_grammars_cmd" || command === "list_word_packs_cmd") {
        return Promise.resolve([]);
      }
      if (command === "set_vocabulary_suspended_cmd") {
        return Promise.resolve({
          id: "v1",
          word: "abandon",
          meaning: "放弃",
          suspended_at: "2026-09-09T00:00:00Z",
        });
      }
      if (command === "delete_favorite_vocabulary_cmd") {
        return Promise.resolve(null);
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("abandon");

    await userEvent.click(screen.getByTitle("标记已掌握"));
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("set_vocabulary_suspended_cmd", {
        vocabularyId: "v1",
        suspended: true,
      });
    });

    const card = screen.getByText("abandon").closest(".group") as HTMLElement;
    const cardButtons = within(card).getAllByRole("button");
    await userEvent.click(cardButtons[cardButtons.length - 1]);
    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("delete_favorite_vocabulary_cmd", { id: "v1" });
    });
    expect(screen.queryByText("abandon")).not.toBeInTheDocument();
    expect(consoleSpy).not.toHaveBeenCalled();
    consoleSpy.mockRestore();
  });

  it("edits a vocabulary through the edit dialog", async () => {
    mockFavoritesData();
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([
          {
            id: "v1",
            word: "abandon",
            meaning: "放弃",
            usage: "v.",
            example: "He abandoned the plan.",
            reading: "əˈbændən",
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
      if (command === "update_favorite_vocabulary_cmd") {
        return Promise.resolve({
          id: "v1",
          word: "abandons",
          meaning: "放弃",
        });
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("abandon");
    await userEvent.click(screen.getByTitle("编辑单词"));

    const dialogRoot = (await screen.findByText("编辑单词")).closest(".relative") as HTMLElement;
    const inputs = within(dialogRoot).getAllByRole("textbox");
    await userEvent.clear(inputs[0]);
    await userEvent.type(inputs[0], "abandons");
    await userEvent.click(within(dialogRoot).getByRole("button", { name: "保存" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "update_favorite_vocabulary_cmd",
        expect.objectContaining({ vocabularyId: "v1", word: "abandons" })
      );
    });
  });

  it("adds a vocabulary through the add dialog", async () => {
    mockFavoritesData();
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_favorite_grammars_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_word_packs_cmd") {
        return Promise.resolve([{ id: "p1", name: "TOEFL", is_system: false }]);
      }
      if (command === "add_favorite_vocabulary_cmd") {
        return Promise.resolve({ id: "v2", word: "hello", meaning: "你好" });
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("暂无单词收藏");
    await userEvent.click(screen.getByRole("button", { name: "添加单词" }));

    const dialogRoot = (await screen.findByText("手动添加单词")).closest(".relative") as HTMLElement;
    const inputs = within(dialogRoot).getAllByRole("textbox");
    await userEvent.type(inputs[0], "hello");
    await userEvent.type(inputs[1], "你好");
    await userEvent.click(within(dialogRoot).getByRole("button", { name: "添加" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "add_favorite_vocabulary_cmd",
        expect.objectContaining({ word: "hello", meaning: "你好", packIds: null })
      );
    });
    // 添加成功后应重新加载收藏列表
    const listCalls = invokeMock.mock.calls.filter(
      (call) => call[0] === "list_favorite_vocabularies_cmd"
    );
    expect(listCalls.length).toBeGreaterThanOrEqual(2);
  });

  it("exports Anki TSV from the pack menu", async () => {
    mockFavoritesData();
    saveMock.mockResolvedValue("/tmp/anki.txt");

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findAllByText("abandon");
    await userEvent.click(screen.getByRole("button", { name: "全部单词操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "导出 Anki 文件 (TSV)" }));

    await waitFor(() => {
      expect(saveMock).toHaveBeenCalledWith(
        expect.objectContaining({ defaultPath: "全部单词-anki.txt" })
      );
    });
    await waitFor(() => {
      const writeCall = invokeMock.mock.calls.find((call) => call[0] === "write_text_file");
      expect(writeCall?.[1]?.content).toEqual(expect.stringContaining("abandon"));
    });
  });

  it("exports the transfer bundle for phone migration", async () => {
    mockFavoritesData();
    const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {});
    saveMock.mockResolvedValue("/tmp/openkoto-data.okdata");
    invokeMock.mockImplementation((command: string) => {
      if (command === "export_transfer_bundle_cmd") {
        return Promise.resolve({
          file_name: "openkoto-data-2026-09-09.okdata",
          json_content: "{\"format\":\"openkoto-transfer-v1\"}",
          vocabulary: 3,
          packs: 1,
          articles: 2,
          segments: 5,
          review_events: 9,
          skipped: 0,
        });
      }
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([
          {
            id: "v1",
            word: "abandon",
            meaning: "放弃",
            pack_ids: ["p1"],
            created_at: "2026-02-16T00:00:00Z",
          },
        ]);
      }
      if (command === "list_favorite_grammars_cmd" || command === "list_word_packs_cmd") {
        return Promise.resolve([]);
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("abandon");
    await userEvent.click(screen.getByRole("button", { name: "导出到手机" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("export_transfer_bundle_cmd", {
        includeContent: true,
      });
    });
    await waitFor(() => {
      expect(saveMock).toHaveBeenCalledWith(
        expect.objectContaining({ defaultPath: "openkoto-data-2026-09-09.okdata" })
      );
    });
    const writeCall = invokeMock.mock.calls.find((call) => call[0] === "write_text_file");
    expect(writeCall?.[1]?.content).toContain("openkoto-transfer-v1");
    expect(alertSpy).toHaveBeenCalled();
    alertSpy.mockRestore();
  });

  it("renders the grammar list and deletes a grammar entry", async () => {
    mockFavoritesData();
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_favorite_grammars_cmd") {
        return Promise.resolve([
          {
            id: "g1",
            point: "〜てしまう",
            explanation: "表示彻底完成或遗憾",
            example: "食べてしまう",
            source_article_id: "a1",
            source_article_title: "Source Article",
            created_at: "2026-02-16T00:00:00Z",
          },
        ]);
      }
      if (command === "list_word_packs_cmd") {
        return Promise.resolve([]);
      }
      if (command === "delete_favorite_grammar_cmd") {
        return Promise.resolve(null);
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await userEvent.click(screen.getByText("语法收藏"));
    expect(await screen.findByText("〜てしまう")).toBeInTheDocument();

    const card = screen.getByText("〜てしまう").closest(".group") as HTMLElement;
    const cardButtons = within(card).getAllByRole("button");
    await userEvent.click(cardButtons[cardButtons.length - 1]);

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("delete_favorite_grammar_cmd", { id: "g1" });
    });
    expect(screen.queryByText("〜てしまう")).not.toBeInTheDocument();
  });

  it("opens the recite panel from the pack manager", async () => {
    mockFavoritesData();
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_favorite_grammars_cmd" || command === "list_word_packs_cmd") {
        return Promise.resolve([]);
      }
      if (command === "get_due_vocabulary_queue_cmd") {
        return Promise.resolve([]);
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("暂无单词收藏");
    await userEvent.click(screen.getByRole("button", { name: "开始复习" }));

    expect(await screen.findByText(/今日复习/)).toBeInTheDocument();
  });

  it("submits the new-pack dialog with Enter and clears it on cancel", async () => {
    mockFavoritesData();

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("单词合集");
    const newButtons = screen.getAllByRole("button", { name: "新建" });
    await userEvent.click(newButtons[newButtons.length - 1]);

    const nameInput = await screen.findByPlaceholderText("输入新合集名称");
    await userEvent.type(nameInput, "N1 词汇{enter}");

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "create_word_pack_cmd",
        expect.objectContaining({ name: "N1 词汇" })
      );
    });

    await userEvent.click(newButtons[newButtons.length - 1]);
    const reopenedInput = await screen.findByPlaceholderText("输入新合集名称");
    expect(reopenedInput).toHaveValue("");

    const createDialogRoot = screen.getByText("新建单词合集").closest(".relative") as HTMLElement;
    await userEvent.click(within(createDialogRoot).getByRole("button", { name: "取消" }));
    await waitFor(() => {
      expect(screen.queryByText("新建单词合集")).not.toBeInTheDocument();
    });
  });

  it("logs errors from stats, favorites load, pack creation, copy, and export paths", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const clipboardSpy = vi.spyOn(navigator.clipboard, "writeText").mockRejectedValue("denied");
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([
          {
            id: "v1",
            word: "abandon",
            meaning: "放弃",
            pack_ids: ["p1"],
            source_article_id: "a1",
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
      if (command === "get_review_stats_cmd") {
        return Promise.reject("stats down");
      }
      if (command === "get_article") {
        return Promise.reject("deleted");
      }
      if (command === "create_word_pack_cmd") {
        return Promise.reject("insert failed");
      }
      if (command === "export_word_pack_cmd") {
        return Promise.resolve({
          file_name: "TOEFL.okpack.json",
          json_content: "{}",
        });
      }
      if (command === "write_text_file") {
        return Promise.reject("disk full");
      }
      return Promise.resolve(null);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("abandon");
    expect(consoleSpy.mock.calls.some((call) => call[0] === "Failed to load review stats:")).toBe(true);

    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "删除合集" }));
    expect(invokeMock).not.toHaveBeenCalledWith("delete_word_pack_cmd", { id: "p1" });

    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "复制到剪贴板" }));
    await waitFor(() => {
      expect(consoleSpy.mock.calls.some((call) => call[0] === "Failed to copy:")).toBe(true);
    });

    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "下载 TXT 文件" }));
    await waitFor(() => {
      expect(consoleSpy.mock.calls.some((call) => call[0] === "Failed to write txt file:")).toBe(true);
    });

    await userEvent.click(screen.getByRole("button", { name: "TOEFL操作" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "导出单词包" }));
    await waitFor(() => {
      expect(consoleSpy.mock.calls.some((call) => call[0] === "Failed to export word pack:")).toBe(true);
    });

    const newButtons = screen.getAllByRole("button", { name: "新建" });
    await userEvent.click(newButtons[newButtons.length - 1]);
    const nameInput = await screen.findByPlaceholderText("输入新合集名称");
    await userEvent.type(nameInput, "Broken");
    await userEvent.click(screen.getByRole("button", { name: "创建" }));
    await waitFor(() => {
      expect(consoleSpy.mock.calls.some((call) => call[0] === "Failed to create pack:")).toBe(true);
    });

    clipboardSpy.mockRestore();
    confirmSpy.mockRestore();
    consoleSpy.mockRestore();
  });

  it("resets the pack selection to all when the selected pack disappears", async () => {
    let packs: Array<{ id: string; name: string; is_system: boolean }> = [
      { id: "p1", name: "TOEFL", is_system: false },
    ];
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_favorite_grammars_cmd") {
        return Promise.resolve([]);
      }
      if (command === "list_word_packs_cmd") {
        return Promise.resolve(packs);
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

    class MockFileReader {
      onload: ((event: { target: { result: string } }) => void) | null = null;

      readAsText() {
        this.onload?.({ target: { result: "{}" } });
        packs = [];
      }
    }

    vi.stubGlobal("FileReader", MockFileReader);

    const { container } = render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await screen.findByText("TOEFL");
    const packRow = screen
      .getAllByRole("button", { name: /TOEFL/ })
      .find((button) => !button.textContent?.includes("操作"));
    await userEvent.click(packRow!);
    await waitFor(() => {
      const statsCalls = invokeMock.mock.calls.filter((call) => call[0] === "get_review_stats_cmd");
      expect(statsCalls.length).toBeGreaterThan(0);
      expect(statsCalls[statsCalls.length - 1][1]).toEqual(
        expect.objectContaining({ packId: "p1" })
      );
    });

    fireEvent.change(container.querySelector('input[type="file"]') as Element, {
      target: {
        files: [new File(["{}"], "all.okpack.json", { type: "application/json" })],
      },
    });

    await waitFor(() => {
      const statsCalls = invokeMock.mock.calls.filter((call) => call[0] === "get_review_stats_cmd");
      const last = statsCalls[statsCalls.length - 1][1] as Record<string, string>;
      expect(last.packId).toBe("all");
    });
  });

  it("logs an error when loading favorites fails", async () => {
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_favorite_vocabularies_cmd") {
        return Promise.reject("db locked");
      }
      return Promise.resolve([]);
    });

    render(<FavoritesPage onBack={() => {}} onSelectArticle={() => {}} />);

    await waitFor(() => {
      expect(consoleSpy.mock.calls.some((call) => call[0] === "Failed to load favorites:")).toBe(true);
    });
    expect(screen.getByText("暂无单词收藏")).toBeInTheDocument();
    consoleSpy.mockRestore();
  });
});
