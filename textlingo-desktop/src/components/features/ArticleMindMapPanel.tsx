import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { useTranslation } from "react-i18next";
import { AlertCircle, BookOpen, Loader2, RefreshCw, Sparkles, TerminalSquare } from "lucide-react";

import { Button } from "../ui/button";
import {
  AgentTask,
  AgentWorkerStatusSnapshot,
  Artifact,
  Article,
  MindMapNode,
  MindMapResult,
  WorkerLogEntry,
} from "../../types";

interface ArticleMindMapPanelProps {
  article: Article;
  targetLanguage: string;
}

function TreeNode({ node }: { node: MindMapNode }) {
  return (
    <li className="relative pl-4">
      <div className="absolute left-0 top-3 h-px w-3 bg-border" />
      <div className="rounded-xl border border-border bg-background px-3 py-3 shadow-sm">
        <p className="text-sm font-semibold text-foreground">{node.title}</p>
        <p className="mt-1 text-xs leading-5 text-muted-foreground">{node.summary}</p>
      </div>
      {node.children.length > 0 && (
        <ul className="ml-3 mt-3 space-y-3 border-l border-dashed border-border/80 pl-4">
          {node.children.map((child) => (
            <TreeNode key={child.id} node={child} />
          ))}
        </ul>
      )}
    </li>
  );
}

function formatTimestamp(value?: string) {
  if (!value) {
    return "—";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return date.toLocaleString();
}

function StatusBadge({
  health,
  labels,
}: {
  health: AgentWorkerStatusSnapshot["health"];
  labels: Record<AgentWorkerStatusSnapshot["health"], string>;
}) {
  const styles: Record<AgentWorkerStatusSnapshot["health"], string> = {
    healthy: "bg-green-500/15 text-green-700",
    starting: "bg-amber-500/15 text-amber-700",
    unhealthy: "bg-destructive/15 text-destructive",
    stopped: "bg-muted text-muted-foreground",
  };

  return (
    <span className={`rounded-full px-2 py-1 text-[11px] font-medium ${styles[health]}`}>
      {labels[health]}
    </span>
  );
}

function AgentLogPanel({
  status,
  title,
  labels,
}: {
  status: AgentWorkerStatusSnapshot | null;
  title: string;
  labels: {
    session: string;
    startedAt: string;
    lastHeartbeat: string;
    empty: string;
    health: Record<AgentWorkerStatusSnapshot["health"], string>;
  };
}) {
  if (!status) {
    return null;
  }

  const logs = status.logs.slice(-8).reverse();

  return (
    <div className="mt-4 rounded-2xl border border-border bg-card/70 p-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <TerminalSquare size={16} className="text-muted-foreground" />
          <p className="text-xs font-semibold tracking-wide text-foreground">{title}</p>
        </div>
        <StatusBadge health={status.health} labels={labels.health} />
      </div>

      <div className="mt-3 grid grid-cols-1 gap-2 text-[11px] text-muted-foreground">
        <div className="flex justify-between gap-3">
          <span>{labels.session}</span>
          <span className="font-mono text-foreground">{status.worker_session_id || "—"}</span>
        </div>
        <div className="flex justify-between gap-3">
          <span>{labels.startedAt}</span>
          <span>{formatTimestamp(status.started_at)}</span>
        </div>
        <div className="flex justify-between gap-3">
          <span>{labels.lastHeartbeat}</span>
          <span>{formatTimestamp(status.last_heartbeat_at)}</span>
        </div>
      </div>

      <div className="mt-4 rounded-xl border border-border bg-background">
        <div className="border-b border-border px-3 py-2 text-[11px] font-medium text-muted-foreground">
          Logs
        </div>
        {logs.length === 0 ? (
          <div className="px-3 py-4 text-[11px] text-muted-foreground">{labels.empty}</div>
        ) : (
          <div className="max-h-44 overflow-y-auto px-3 py-2 font-mono text-[11px]">
            {logs.map((entry: WorkerLogEntry, index) => (
              <div key={`${entry.timestamp}-${index}`} className="py-1 text-muted-foreground">
                <span className="mr-2 text-foreground">[{entry.level}]</span>
                <span className="mr-2">{entry.source}</span>
                <span>{entry.message}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

export function ArticleMindMapPanel({
  article,
  targetLanguage,
}: ArticleMindMapPanelProps) {
  const { t } = useTranslation();
  const [task, setTask] = useState<AgentTask | null>(null);
  const [artifact, setArtifact] = useState<Artifact | null>(null);
  const [result, setResult] = useState<MindMapResult | null>(null);
  const [workerStatus, setWorkerStatus] = useState<AgentWorkerStatusSnapshot | null>(null);
  const [isCreatingTask, setIsCreatingTask] = useState(false);
  const [isLoadingArtifact, setIsLoadingArtifact] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const workerLabels = {
    session: t("articleReader.mindMapPanel.agentSession", "会话"),
    startedAt: t("articleReader.mindMapPanel.agentStartedAt", "启动时间"),
    lastHeartbeat: t("articleReader.mindMapPanel.agentHeartbeat", "最近心跳"),
    empty: t("articleReader.mindMapPanel.agentLogEmpty", "当前还没有日志"),
    health: {
      healthy: t("articleReader.mindMapPanel.agentHealth.healthy", "正常"),
      starting: t("articleReader.mindMapPanel.agentHealth.starting", "启动中"),
      unhealthy: t("articleReader.mindMapPanel.agentHealth.unhealthy", "异常"),
      stopped: t("articleReader.mindMapPanel.agentHealth.stopped", "未启动"),
    } satisfies Record<AgentWorkerStatusSnapshot["health"], string>,
  };

  useEffect(() => {
    let unlistenTask: UnlistenFn | undefined;
    let unlistenStatus: UnlistenFn | undefined;

    const loadCurrentArtifact = async (artifactId: string) => {
      setIsLoadingArtifact(true);
      try {
        const nextArtifact = await invoke<Artifact>("get_artifact_cmd", {
          articleId: article.id,
          artifactId,
        });
        setArtifact(nextArtifact);
        setResult(nextArtifact.content as MindMapResult);
      } catch (err) {
        setError(typeof err === "string" ? err : "Failed to load mind map artifact");
      } finally {
        setIsLoadingArtifact(false);
      }
    };

    const refreshWorkerStatus = async () => {
      try {
        const snapshot = await invoke<AgentWorkerStatusSnapshot>("get_agent_worker_status_cmd");
        setWorkerStatus(snapshot);
      } catch (err) {
        console.error("Failed to load agent worker status", err);
      }
    };

    const setup = async () => {
      unlistenTask = await listen<AgentTask>("agent-task-updated", (event) => {
        const nextTask = event.payload;
        if (nextTask.article_id !== article.id) {
          return;
        }

        setTask(nextTask);
        if (nextTask.status === "failed" && nextTask.error) {
          setError(nextTask.error);
        }

        const latestArtifactId = nextTask.artifact_ids[nextTask.artifact_ids.length - 1];
        if (latestArtifactId) {
          void loadCurrentArtifact(latestArtifactId);
        }
      });

      unlistenStatus = await listen<AgentWorkerStatusSnapshot>("agent-worker-status", (event) => {
        setWorkerStatus(event.payload);
      });
    };

    setTask(null);
    setArtifact(null);
    setResult(null);
    setError(null);

    if (article.active_mind_map_artifact_id) {
      void loadCurrentArtifact(article.active_mind_map_artifact_id);
    }

    void refreshWorkerStatus();
    void setup();

    return () => {
      if (unlistenTask) {
        void unlistenTask();
      }
      if (unlistenStatus) {
        void unlistenStatus();
      }
    };
  }, [article.active_mind_map_artifact_id, article.id]);

  const handleGenerate = async () => {
    setIsCreatingTask(true);
    setError(null);
    setResult(null);
    setArtifact(null);
    try {
      const nextTask = await invoke<AgentTask>("create_mind_map_task_cmd", {
        articleId: article.id,
        displayLanguage: targetLanguage,
        maxDepth: 3,
      });
      setTask(nextTask);
    } catch (err) {
      setError(typeof err === "string" ? err : "Failed to start mind map generation");
    } finally {
      setIsCreatingTask(false);
    }
  };

  const activeProgress =
    task && (task.status === "queued" || task.status === "running") ? task : null;

  const panelTitle = t("articleReader.mindMapPanel.agentStatus", "Agent 状态");

  if (isLoadingArtifact) {
    return (
      <div className="h-full overflow-y-auto px-4 py-5">
        <div className="flex items-center justify-center gap-2 py-8 text-muted-foreground">
          <Loader2 size={16} className="animate-spin" />
          <span>{t("articleReader.mindMapPanel.loading", "正在加载思维导图...")}</span>
        </div>
        <AgentLogPanel status={workerStatus} title={panelTitle} labels={workerLabels} />
      </div>
    );
  }

  if (activeProgress) {
    return (
      <div className="h-full overflow-y-auto px-4 py-5">
        <div className="flex flex-col items-center justify-center gap-4 p-8 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary/10 text-primary">
            <Loader2 size={24} className="animate-spin" />
          </div>
          <div className="space-y-1">
            <p className="text-sm font-medium text-foreground">
              {activeProgress.message || t("articleReader.mindMapPanel.generating", "正在生成思维导图")}
            </p>
            <p className="text-xs text-muted-foreground">{Math.round(activeProgress.progress * 100)}%</p>
          </div>
        </div>
        <AgentLogPanel status={workerStatus} title={panelTitle} labels={workerLabels} />
      </div>
    );
  }

  if (error) {
    return (
      <div className="h-full overflow-y-auto px-4 py-5">
        <div className="flex flex-col items-center justify-center gap-4 p-8 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-destructive/10 text-destructive">
            <AlertCircle size={24} />
          </div>
          <div className="space-y-1">
            <p className="text-sm font-medium text-foreground">
              {t("articleReader.mindMapPanel.failed", "思维导图生成失败")}
            </p>
            <p className="text-xs text-muted-foreground">{error}</p>
          </div>
          <Button onClick={handleGenerate} variant="secondary">
            {t("articleReader.mindMapPanel.retry", "重试")}
          </Button>
        </div>
        <AgentLogPanel status={workerStatus} title={panelTitle} labels={workerLabels} />
      </div>
    );
  }

  if (result?.status === "not_applicable") {
    return (
      <div className="h-full overflow-y-auto px-4 py-5">
        <div className="flex flex-col items-center justify-center gap-4 p-8 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-muted text-muted-foreground">
            <BookOpen size={24} />
          </div>
          <div className="space-y-1">
            <p className="text-sm font-medium text-foreground">
              {t("articleReader.mindMapPanel.notApplicable", "当前内容不适合生成思维导图")}
            </p>
            <p className="text-xs leading-5 text-muted-foreground">
              {result.diagnostics.notes[0] ||
                result.reason ||
                t("articleReader.mindMapPanel.notApplicableHint", "当前素材缺少稳定语义内容。")}
            </p>
          </div>
          <Button onClick={handleGenerate} variant="secondary">
            {t("articleReader.mindMapPanel.generateAgain", "重新生成")}
          </Button>
        </div>
        <AgentLogPanel status={workerStatus} title={panelTitle} labels={workerLabels} />
      </div>
    );
  }

  if (result?.map) {
    return (
      <div className="h-full overflow-y-auto px-4 py-5">
        <div className="rounded-2xl border border-border bg-muted/20 p-4">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="text-sm font-semibold text-foreground">{result.map.title}</p>
              <p className="mt-1 text-xs leading-5 text-muted-foreground">{result.map.summary}</p>
            </div>
            {result.status === "partial" && (
              <span className="rounded-full bg-amber-500/15 px-2 py-1 text-[11px] font-medium text-amber-700">
                {t("articleReader.mindMapPanel.partial", "部分覆盖")}
              </span>
            )}
          </div>
        </div>

        <ul className="mt-4 space-y-3">
          <TreeNode node={result.map.root} />
        </ul>

        {artifact && (
          <p className="mt-4 text-[11px] text-muted-foreground">
            {t("articleReader.mindMapPanel.artifactId", "产物 ID")}: {artifact.id}
          </p>
        )}

        <AgentLogPanel status={workerStatus} title={panelTitle} labels={workerLabels} />
      </div>
    );
  }

  return (
    <div className="h-full overflow-y-auto px-4 py-5">
      <div className="flex flex-col items-center justify-center gap-4 p-8 text-center">
        <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary/10 text-primary">
          {isCreatingTask ? <Loader2 size={28} className="animate-spin" /> : <Sparkles size={28} />}
        </div>
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">
            {t("articleReader.mindMapPanel.title", "生成文章思维导图")}
          </p>
          <p className="text-xs leading-5 text-muted-foreground">
            {t(
              "articleReader.mindMapPanel.description",
              "从原始内容提取主题结构，并保留与文章的证据关联。",
            )}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button onClick={handleGenerate} disabled={isCreatingTask}>
            {t("articleReader.mindMapPanel.generate", "生成思维导图")}
          </Button>
          <Button
            onClick={() => invoke("get_agent_worker_status_cmd").then((snapshot) => setWorkerStatus(snapshot as AgentWorkerStatusSnapshot))}
            variant="ghost"
            size="icon"
            title={t("articleReader.mindMapPanel.refreshStatus", "刷新 Agent 状态")}
          >
            <RefreshCw size={16} />
          </Button>
        </div>
      </div>
      <AgentLogPanel status={workerStatus} title={panelTitle} labels={workerLabels} />
    </div>
  );
}
