import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AgentPanel } from "./AgentPanel";

const invokeMock = vi.fn();
const listenerMap = new Map<string, (event: { payload: unknown }) => void>();
const invokeObservations: Array<{ taskId?: string; listenersReady: boolean }> = [];

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (eventName: string, handler: (event: { payload: unknown }) => void) => {
    listenerMap.set(eventName, handler);
    return () => listenerMap.delete(eventName);
  }),
}));

describe("AgentPanel", () => {
  const originalCrypto = globalThis.crypto;

  beforeEach(() => {
    invokeMock.mockResolvedValue({
      health: "stopped",
      logs: [],
    });
  });

  afterEach(() => {
    Object.defineProperty(globalThis, "crypto", {
      value: originalCrypto,
      configurable: true,
    });
    cleanup();
    invokeMock.mockReset();
    listenerMap.clear();
    invokeObservations.length = 0;
  });

  it("shows capability hints and submits user input", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    const onSubmitTurn = vi.fn();

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
        onSubmitTurn={onSubmitTurn}
      />,
    );

    expect(screen.getByText("查看当前素材")).toBeInTheDocument();
    expect(screen.getByText("列出素材")).toBeInTheDocument();
    expect(screen.getByText("打开素材")).toBeInTheDocument();

    const input = screen.getByPlaceholderText("让 AI 帮你操作软件");
    await userEvent.type(input, "打开标题带 N1 的 PDF");
    await userEvent.click(screen.getByRole("button", { name: "发送 Agent 消息" }));

    expect(onSubmitTurn).toHaveBeenCalledWith("打开标题带 N1 的 PDF");
  });

  it("submits from the built-in capability shortcuts", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    const onSubmitTurn = vi.fn();

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
        onSubmitTurn={onSubmitTurn}
      />,
    );

    await userEvent.click(screen.getByRole("button", { name: "列出素材" }));

    expect(onSubmitTurn).toHaveBeenCalledWith("列出素材");
  });

  it("submits an agent turn and renders tool activity plus the assistant reply", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    invokeMock.mockResolvedValue({
      id: "task-1",
      task_type: "assistant_agent_turn",
      status: "queued",
      article_id: "article-1",
      input: {
        article_id: "article-1",
        display_language: "zh-CN",
        max_depth: 0,
        evidence_mode: "none",
        prefer_structure: "none",
      },
      progress: 0,
      artifact_ids: [],
      created_at: "2026-03-08T00:00:00Z",
      updated_at: "2026-03-08T00:00:00Z",
    });

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
      />,
    );

    await userEvent.type(screen.getByPlaceholderText("让 AI 帮你操作软件"), "找出标题带 N1 的 PDF");
    await userEvent.click(screen.getByRole("button", { name: "发送 Agent 消息" }));

    expect(invokeMock).toHaveBeenCalledWith("run_agent_turn_cmd", {
      taskId: "task-1",
      articleId: "article-1",
      userMessage: "找出标题带 N1 的 PDF",
      conversation: [],
      displayLanguage: "zh-CN",
    });

    listenerMap.get("agent-task-log://task-1")?.({
      payload: {
        task_id: "task-1",
        level: "info",
        source: "tool",
        message: 'calling list_materials()',
        timestamp: "2026-03-08T00:00:01Z",
      },
    });
    listenerMap.get("assistant-agent-result://task-1")?.({
      payload: {
        reply: "我找到了 1 个 PDF 素材",
        action: null,
      },
    });

    await waitFor(() => {
      expect(screen.getByText("我找到了 1 个 PDF 素材")).toBeInTheDocument();
    });
    expect(screen.getByText("calling list_materials()")).toBeInTheDocument();
  });

  it("renders markdown only in assistant reply bubbles", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    invokeMock.mockResolvedValue({
      id: "task-1",
      task_type: "assistant_agent_turn",
      status: "queued",
      article_id: "article-1",
      input: {
        article_id: "article-1",
        display_language: "zh-CN",
        max_depth: 0,
        evidence_mode: "none",
        prefer_structure: "none",
      },
      progress: 0,
      artifact_ids: [],
      created_at: "2026-03-08T00:00:00Z",
      updated_at: "2026-03-08T00:00:00Z",
    });

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
      />,
    );

    await userEvent.type(screen.getByPlaceholderText("让 AI 帮你操作软件"), "请回复 **重点**");
    await userEvent.click(screen.getByRole("button", { name: "发送 Agent 消息" }));

    listenerMap.get("assistant-agent-result://task-1")?.({
      payload: {
        reply: "这是 **重点**\n\n- 第一项",
        action: null,
      },
    });

    await waitFor(() => {
      expect(screen.getByText("重点", { selector: "strong" })).toBeInTheDocument();
    });
    expect(screen.getByRole("list")).toBeInTheDocument();

    const userBubble = screen.getByText("请回复 **重点**").closest("div");
    expect(userBubble?.querySelector("strong")).toBeNull();
  });

  it("renders GFM tables in assistant reply bubbles", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    invokeMock.mockResolvedValue({
      id: "task-1",
      task_type: "assistant_agent_turn",
      status: "queued",
      article_id: "article-1",
      input: {
        article_id: "article-1",
        display_language: "zh-CN",
        max_depth: 0,
        evidence_mode: "none",
        prefer_structure: "none",
      },
      progress: 0,
      artifact_ids: [],
      created_at: "2026-03-08T00:00:00Z",
      updated_at: "2026-03-08T00:00:00Z",
    });

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
      />,
    );

    await userEvent.type(screen.getByPlaceholderText("让 AI 帮你操作软件"), "请用表格回复");
    await userEvent.click(screen.getByRole("button", { name: "发送 Agent 消息" }));

    listenerMap.get("assistant-agent-result://task-1")?.({
      payload: {
        reply: "| 项目 | 说明 |\n| --- | --- |\n| 等级 | N1 |",
        action: null,
      },
    });

    await waitFor(() => {
      expect(screen.getByRole("table")).toBeInTheDocument();
    });
    expect(screen.getByRole("columnheader", { name: "项目" })).toBeInTheDocument();
    expect(screen.getByRole("cell", { name: "N1" })).toBeInTheDocument();
  });

  it("subscribes to agent events before invoking the command", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    invokeMock.mockImplementation(async (_command: string, payload: { taskId: string }) => {
      invokeObservations.push({
        taskId: payload.taskId,
        listenersReady:
          listenerMap.has(`agent-task-log://${payload.taskId}`) &&
          listenerMap.has(`assistant-agent-result://${payload.taskId}`),
      });
      return {
        id: payload.taskId,
        task_type: "assistant_agent_turn",
        status: "queued",
        article_id: "article-1",
        input: {
          article_id: "article-1",
          display_language: "zh-CN",
          max_depth: 0,
          evidence_mode: "none",
          prefer_structure: "none",
        },
        progress: 0,
        artifact_ids: [],
        created_at: "2026-03-08T00:00:00Z",
        updated_at: "2026-03-08T00:00:00Z",
      };
    });

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
      />,
    );

    await userEvent.type(screen.getByPlaceholderText("让 AI 帮你操作软件"), "打开 N1 PDF");
    await userEvent.click(screen.getByRole("button", { name: "发送 Agent 消息" }));

    expect(invokeMock).toHaveBeenCalledWith("run_agent_turn_cmd", expect.any(Object));
    expect(invokeObservations).toEqual([
      {
        taskId: "task-1",
        listenersReady: true,
      },
    ]);
  });

  it("renders task failures and worker logs for debugging", async () => {
    Object.defineProperty(globalThis, "crypto", {
      value: {
        randomUUID: () => "task-1",
      },
      configurable: true,
    });

    invokeMock.mockResolvedValue({
      id: "task-1",
      task_type: "assistant_agent_turn",
      status: "queued",
      article_id: "article-1",
      input: {
        article_id: "article-1",
        display_language: "zh-CN",
        max_depth: 0,
        evidence_mode: "none",
        prefer_structure: "none",
      },
      progress: 0,
      artifact_ids: [],
      created_at: "2026-03-08T00:00:00Z",
      updated_at: "2026-03-08T00:00:00Z",
    });

    render(
      <AgentPanel
        articleId="article-1"
        articleTitle="Sample"
        targetLanguage="zh-CN"
      />,
    );

    await userEvent.click(screen.getByRole("button", { name: "列出素材" }));

    listenerMap.get("assistant-agent-error://task-1")?.({
      payload: {
        id: "task-1",
        task_type: "assistant_agent_turn",
        status: "failed",
        article_id: "article-1",
        input: {
          article_id: "article-1",
          display_language: "zh-CN",
          max_depth: 0,
          evidence_mode: "none",
          prefer_structure: "none",
        },
        progress: 0,
        error: "Agent runtime execution failed: timeout",
        artifact_ids: [],
        created_at: "2026-03-08T00:00:00Z",
        updated_at: "2026-03-08T00:00:02Z",
      },
    });
    listenerMap.get("agent-worker-status")?.({
      payload: {
        health: "healthy",
        logs: [
          {
            timestamp: "2026-03-08T00:00:03Z",
            level: "warn",
            source: "stderr",
            message: "opencode add --force --exact --cwd /tmp/test oh-my-opencode@latest",
          },
        ],
      },
    });

    await waitFor(() => {
      expect(screen.getAllByText("Agent runtime execution failed: timeout").length).toBeGreaterThan(0);
    });
    expect(screen.getByText("Worker 日志")).toBeInTheDocument();
    expect(screen.getByText("opencode add --force --exact --cwd /tmp/test oh-my-opencode@latest")).toBeInTheDocument();
  });
});
