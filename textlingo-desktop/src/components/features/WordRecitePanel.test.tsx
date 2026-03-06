import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { vi, afterEach, beforeEach, describe, expect, it } from "vitest";
import { WordRecitePanel } from "./WordRecitePanel";

const invokeMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

describe("WordRecitePanel", () => {
  beforeEach(() => {
    invokeMock.mockReset();
  });

  afterEach(() => {
    cleanup();
  });

  it("loads due queue and submits review grade", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "get_due_vocabulary_queue_cmd") {
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
      if (command === "review_vocabulary_cmd") {
        return Promise.resolve({});
      }
      return Promise.resolve(null);
    });

    const onReviewed = vi.fn(async () => {});

    render(
      <WordRecitePanel
        open
        onOpenChange={() => {}}
        packId="p1"
        packName="TOEFL"
        onReviewed={onReviewed}
      />
    );

    await screen.findByText("abandon");
    await userEvent.click(screen.getByRole("button", { name: "显示答案" }));
    await userEvent.click(screen.getByRole("button", { name: "认识" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "review_vocabulary_cmd",
        expect.objectContaining({ vocabularyId: "v1", grade: "known" })
      );
      expect(onReviewed).toHaveBeenCalled();
    });
  });

  it("shows completed state when there are no due cards", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "get_due_vocabulary_queue_cmd") {
        return Promise.resolve([]);
      }
      return Promise.resolve(null);
    });

    render(
      <WordRecitePanel
        open
        onOpenChange={() => {}}
        packId="all"
        packName="全部单词"
        onReviewed={() => {}}
      />
    );

    expect(await screen.findByText("今日已完成")).toBeInTheDocument();
    expect(screen.getAllByText("当前没有到期卡片").length).toBeGreaterThan(0);
  });

  it("handles queue load failure and uncertain grading", async () => {
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    invokeMock.mockImplementation((command: string) => {
      if (command === "get_due_vocabulary_queue_cmd") {
        return Promise.reject(new Error("load failed"));
      }
      return Promise.resolve(null);
    });

    render(
      <WordRecitePanel
        open
        onOpenChange={() => {}}
        packId="p1"
        packName="TOEFL"
        onReviewed={() => {}}
      />
    );

    expect(await screen.findByText("今日已完成")).toBeInTheDocument();
    expect(consoleErrorSpy).toHaveBeenCalledWith("Failed to load due queue:", expect.any(Error));

    invokeMock.mockReset();
    invokeMock.mockImplementation((command: string) => {
      if (command === "get_due_vocabulary_queue_cmd") {
        return Promise.resolve([
          {
            id: "v2",
            word: "ability",
            meaning: "能力",
            usage: "n.",
            pack_ids: ["p1"],
            srs_state: "new",
            due_date: "2026-02-16",
            review_count: 0,
            created_at: "2026-02-16T00:00:00Z",
          },
        ]);
      }
      if (command === "review_vocabulary_cmd") {
        return Promise.resolve({});
      }
      return Promise.resolve(null);
    });

    cleanup();

    const onReviewed = vi.fn();
    render(
      <WordRecitePanel
        open
        onOpenChange={() => {}}
        packId="p1"
        packName="TOEFL"
        onReviewed={onReviewed}
      />
    );

    await screen.findByText("ability");
    await userEvent.click(screen.getByRole("button", { name: "显示答案" }));
    await userEvent.click(screen.getByRole("button", { name: "模糊" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "review_vocabulary_cmd",
        expect.objectContaining({ vocabularyId: "v2", grade: "uncertain" })
      );
      expect(onReviewed).toHaveBeenCalled();
    });

    consoleErrorSpy.mockRestore();
  });
});
