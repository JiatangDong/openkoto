import { describe, expect, it, vi } from "vitest";

import { runAssistantTask } from "./assistantTask.js";

describe("assistantTask", () => {
  it("returns a normalized assistant reply with an open action", async () => {
    const reportProgress = vi.fn(async () => undefined);
    const log = vi.fn();

    const result = await runAssistantTask(
      {
        taskId: "task-1",
        userMessage: "打开标题带 N1 的 PDF",
        conversation: [],
        uiContext: {
          current_article_id: "article-1",
          display_language: "zh-CN",
        },
        currentMaterial: {
          id: "article-1",
          title: "Current PDF",
          material_type: "pdf",
          created_at: "2026-03-08T00:00:00Z",
          translated: false,
        },
        availableMaterials: [
          {
            id: "article-2",
            title: "N1 PDF",
            material_type: "pdf",
            created_at: "2026-03-08T00:00:00Z",
            translated: true,
          },
        ],
      },
      {
        reportProgress,
        log,
        promptRunner: vi.fn(async () => ({
          reply: "我已经找到并打开了 N1 PDF。",
          action: {
            kind: "open_material",
            material_id: "article-2",
          },
        })),
        providerConfig: {
          kind: "native_google",
          provider: "google",
          model: "gemini-2.0-flash-exp",
          api_key: "secret",
        },
      },
    );

    expect(result.reply).toBe("我已经找到并打开了 N1 PDF。");
    expect(result.action?.kind).toBe("open_material");
    expect(log).toHaveBeenCalledWith("info", 'calling open_material(material_id="article-2")', "tool");
    expect(reportProgress).toHaveBeenCalled();
  });

  it("falls back to a reply-only result when the model returns an unknown action kind", async () => {
    const reportProgress = vi.fn(async () => undefined);
    const log = vi.fn();

    const result = await runAssistantTask(
      {
        taskId: "task-2",
        userMessage: "列出素材",
        conversation: [],
        uiContext: {
          current_article_id: "article-1",
          display_language: "zh-CN",
        },
        currentMaterial: {
          id: "article-1",
          title: "Current PDF",
          material_type: "pdf",
          created_at: "2026-03-08T00:00:00Z",
          translated: false,
        },
        availableMaterials: [
          {
            id: "article-2",
            title: "N1 PDF",
            material_type: "pdf",
            created_at: "2026-03-08T00:00:00Z",
            translated: true,
          },
        ],
      },
      {
        reportProgress,
        log,
        promptRunner: vi.fn(async () => ({
          reply: "我找到 1 个素材。",
          action: {
            kind: "null",
          },
        })),
        providerConfig: {
          kind: "native_google",
          provider: "google",
          model: "gemini-2.0-flash-exp",
          api_key: "secret",
        },
      },
    );

    expect(result).toEqual({
      reply: "我找到 1 个素材。",
      action: null,
    });
    expect(log).toHaveBeenCalledWith("warn", expect.stringContaining("Unknown assistant action kind"), "recipe");
  });
});
