import { FormEvent, useEffect, useRef, useState } from "react";
import { Send } from "lucide-react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { MarkdownContent } from "../ui/MarkdownContent";
import type { AgentTask, AgentWorkerStatusSnapshot } from "../../types";

interface AgentPanelProps {
  articleId: string;
  articleTitle: string;
  targetLanguage: string;
  onSubmitTurn?: (message: string) => void | Promise<void>;
}

interface AgentMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
}

interface AgentResultPayload {
  reply: string;
  action?: {
    kind: string;
    material_id?: string;
  } | null;
}

interface AgentLogPayload {
  task_id: string;
  level: "debug" | "info" | "warn" | "error";
  source: "runtime" | "provider" | "tool" | "recipe";
  message: string;
  timestamp: string;
}

interface CapabilityAction {
  key: string;
  label: string;
  prompt: string;
}

export function AgentPanel({
  articleId,
  articleTitle,
  targetLanguage,
  onSubmitTurn,
}: AgentPanelProps) {
  const { t } = useTranslation();
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState<AgentMessage[]>([]);
  const [toolLogs, setToolLogs] = useState<string[]>([]);
  const [workerLogs, setWorkerLogs] = useState<AgentWorkerStatusSnapshot["logs"]>([]);
  const [statusText, setStatusText] = useState<string | null>(null);
  const [errorText, setErrorText] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const taskUnlistenRef = useRef<UnlistenFn[]>([]);

  const capabilityActions: CapabilityAction[] = [
    {
      key: "current",
      label: t("assistant.agent.capabilities.current", "查看当前素材"),
      prompt: t("assistant.agent.prompts.current", "查看当前素材"),
    },
    {
      key: "list",
      label: t("assistant.agent.capabilities.list", "列出素材"),
      prompt: t("assistant.agent.prompts.list", "列出素材"),
    },
    {
      key: "open",
      label: t("assistant.agent.capabilities.open", "打开素材"),
      prompt: t("assistant.agent.prompts.open", "打开素材"),
    },
  ];

  const clearTaskSubscriptions = async () => {
    for (const unlisten of taskUnlistenRef.current) {
      await unlisten();
    }
    taskUnlistenRef.current = [];
  };

  const submitAgentTurn = async (rawMessage: string) => {
    const message = rawMessage.trim();
    if (!message) {
      return;
    }

    setErrorText(null);
    setStatusText(t("assistant.agent.status.submitting", "正在发送任务"));
    setMessages((current) => [
      ...current,
      {
        id: `${Date.now()}-user`,
        role: "user",
        content: message,
      },
    ]);

    await onSubmitTurn?.(message);

    if (onSubmitTurn) {
      setInput("");
      return;
    }

    setIsSubmitting(true);
    setInput("");
    const taskId = crypto.randomUUID();

    try {
      const [unlistenLog, unlistenResult, unlistenError, unlistenProgress] = await Promise.all([
        listen<AgentLogPayload>(`agent-task-log://${taskId}`, (agentEvent) => {
          setToolLogs((current) => [...current, agentEvent.payload.message]);
        }),
        listen<AgentResultPayload>(`assistant-agent-result://${taskId}`, (agentEvent) => {
          setMessages((current) => [
            ...current,
            {
              id: `${Date.now()}-assistant`,
              role: "assistant",
              content: agentEvent.payload.reply,
            },
          ]);
          setErrorText(null);
          setStatusText(t("assistant.agent.status.completed", "任务已完成"));
          setIsSubmitting(false);
        }),
        listen<AgentTask>(`assistant-agent-error://${taskId}`, (agentEvent) => {
          const nextError = agentEvent.payload.error ?? t("assistant.agent.status.failed", "任务失败");
          setErrorText(nextError);
          setStatusText(nextError);
          setToolLogs((current) => [...current, nextError]);
          setIsSubmitting(false);
        }),
        listen<AgentTask>(`assistant-agent-progress://${taskId}`, (agentEvent) => {
          setStatusText(agentEvent.payload.message ?? agentEvent.payload.stage ?? null);
        }),
      ]);

      await clearTaskSubscriptions();
      taskUnlistenRef.current = [unlistenLog, unlistenResult, unlistenError, unlistenProgress];

      await invoke<AgentTask>("run_agent_turn_cmd", {
        taskId,
        articleId,
        userMessage: message,
        conversation: messages.map((item) => ({
          role: item.role,
          content: item.content,
        })),
        displayLanguage: targetLanguage,
      });
    } catch (error) {
      const nextError =
        typeof error === "string" ? error : t("assistant.agent.status.failed", "任务失败");
      setErrorText(nextError);
      setStatusText(nextError);
      setToolLogs((current) => [...current, nextError]);
      setIsSubmitting(false);
      await clearTaskSubscriptions();
    }
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    await submitAgentTurn(input);
  };

  useEffect(() => {
    let cancelled = false;
    let unlistenStatus: UnlistenFn | undefined;

    const syncWorkerStatus = (snapshot: AgentWorkerStatusSnapshot) => {
      if (cancelled) {
        return;
      }
      setWorkerLogs(snapshot.logs.slice(-8).reverse());
    };

    void Promise.resolve(invoke<AgentWorkerStatusSnapshot>("get_agent_worker_status_cmd"))
      .then(syncWorkerStatus)
      .catch(() => undefined);

    void listen<AgentWorkerStatusSnapshot>("agent-worker-status", (event) => {
      syncWorkerStatus(event.payload);
    }).then((fn) => {
      unlistenStatus = fn;
    });

    return () => {
      cancelled = true;
      unlistenStatus?.();
      for (const unlisten of taskUnlistenRef.current) {
        void unlisten();
      }
      taskUnlistenRef.current = [];
    };
  }, []);

  return (
    <div
      className="flex h-full min-h-0 flex-col bg-card"
      data-article-id={articleId}
      data-article-title={articleTitle}
      data-target-language={targetLanguage}
    >
      <div className="border-b border-border px-4 py-3">
        <div className="text-sm font-medium text-foreground">
          {t("assistant.agent.capabilitiesTitle", "当前支持")}
        </div>
        <div className="mt-2 flex flex-wrap gap-2">
          {capabilityActions.map((action) => (
            <Button
              key={action.key}
              type="button"
              variant="outline"
              size="sm"
              disabled={isSubmitting}
              className="h-8 rounded-full px-3 text-xs"
              onClick={() => void submitAgentTurn(action.prompt)}
            >
              {action.label}
            </Button>
          ))}
        </div>
      </div>

      <div className="flex-1 min-h-0 space-y-4 overflow-y-auto px-4 py-4">
        {messages.length === 0 && toolLogs.length === 0 && workerLogs.length === 0 && !errorText ? (
          <div className="rounded-2xl border border-dashed border-border bg-muted/30 p-4 text-sm text-muted-foreground">
            {t(
              "assistant.agent.empty",
              "Agent 会在这里展示执行状态、工具调用记录和回复结果。",
            )}
          </div>
        ) : null}

        {statusText ? (
          <div className="rounded-xl border border-border bg-muted/40 px-3 py-2 text-xs text-muted-foreground">
            {statusText}
          </div>
        ) : null}

        {errorText ? (
          <div className="rounded-2xl border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
            <div className="font-medium">{t("assistant.agent.errorTitle", "任务错误")}</div>
            <div className="mt-1 whitespace-pre-wrap break-words">{errorText}</div>
          </div>
        ) : null}

        {messages.length > 0 ? (
          <div className="space-y-3">
            {messages.map((message) => (
              <div
                key={message.id}
                className={
                  message.role === "user"
                    ? "ml-auto max-w-[90%] rounded-2xl bg-primary px-4 py-3 text-sm text-primary-foreground"
                    : "mr-auto max-w-[90%] rounded-2xl border border-border bg-background px-4 py-3 text-sm text-foreground"
                }
              >
                {message.role === "assistant" ? (
                  <MarkdownContent content={message.content} />
                ) : (
                  message.content
                )}
              </div>
            ))}
          </div>
        ) : null}

        {toolLogs.length > 0 ? (
          <div className="rounded-2xl border border-border bg-muted/30 p-4">
            <div className="mb-2 text-xs font-medium text-foreground">
              {t("assistant.agent.toolLogTitle", "工具调用")}
            </div>
            <div className="space-y-2 text-xs text-muted-foreground">
              {toolLogs.map((log, index) => (
                <div key={`${log}-${index}`} className="rounded-lg bg-background px-3 py-2 font-mono">
                  {log}
                </div>
              ))}
            </div>
          </div>
        ) : null}

        {workerLogs.length > 0 ? (
          <div className="rounded-2xl border border-border bg-muted/20 p-4">
            <div className="mb-2 text-xs font-medium text-foreground">
              {t("assistant.agent.workerLogTitle", "Worker 日志")}
            </div>
            <div className="space-y-2 text-xs text-muted-foreground">
              {workerLogs.map((log, index) => (
                <div
                  key={`${log.timestamp}-${log.source}-${index}`}
                  className="rounded-lg border border-border/60 bg-background px-3 py-2"
                >
                  <div className="font-mono text-[11px] uppercase tracking-wide text-muted-foreground/80">
                    {[log.level, log.source].join(" / ")}
                  </div>
                  <div className="mt-1 break-words font-mono text-[11px] text-foreground">{log.message}</div>
                </div>
              ))}
            </div>
          </div>
        ) : null}
      </div>

      <form className="border-t border-border bg-card p-4" onSubmit={handleSubmit}>
        <div className="flex items-center gap-2">
          <Input
            value={input}
            onChange={(event) => setInput(event.target.value)}
            placeholder={t("assistant.agent.inputPlaceholder", "让 AI 帮你操作软件")}
          />
          <Button
            type="submit"
            aria-label={t("assistant.agent.sendAriaLabel", "发送 Agent 消息")}
            title={t("assistant.agent.sendAriaLabel", "发送 Agent 消息")}
            disabled={!input.trim() || isSubmitting}
            className="h-10 w-10 shrink-0 px-0"
          >
            <Send size={16} />
          </Button>
        </div>
      </form>
    </div>
  );
}
