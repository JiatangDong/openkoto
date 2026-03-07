import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { BookOpen, Loader2, Sparkles, AlertCircle } from "lucide-react";

import { Button } from "../ui/button";
import { Article, AgentTask, Artifact, MindMapNode, MindMapResult } from "../../types";

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

export function ArticleMindMapPanel({
  article,
  targetLanguage,
}: ArticleMindMapPanelProps) {
  const [task, setTask] = useState<AgentTask | null>(null);
  const [artifact, setArtifact] = useState<Artifact | null>(null);
  const [result, setResult] = useState<MindMapResult | null>(null);
  const [isCreatingTask, setIsCreatingTask] = useState(false);
  const [isLoadingArtifact, setIsLoadingArtifact] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let unlisten: UnlistenFn | undefined;

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

    const setup = async () => {
      unlisten = await listen<AgentTask>("agent-task-updated", (event) => {
        const nextTask = event.payload;
        if (nextTask.article_id !== article.id) {
          return;
        }

        setTask(nextTask);
        if (nextTask.status === "failed" && nextTask.error) {
          setError(nextTask.error);
        }

        const latestArtifactId = nextTask.artifact_ids[nextTask.artifact_ids.length - 1];
        if (latestArtifactId && nextTask.status === "succeeded") {
          void loadCurrentArtifact(latestArtifactId);
        }
      });
    };

    setTask(null);
    setArtifact(null);
    setResult(null);
    setError(null);

    if (article.active_mind_map_artifact_id) {
      void loadCurrentArtifact(article.active_mind_map_artifact_id);
    }

    void setup();

    return () => {
      if (unlisten) {
        void unlisten();
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

  if (isLoadingArtifact) {
    return (
      <div className="h-full flex items-center justify-center text-muted-foreground gap-2">
        <Loader2 size={16} className="animate-spin" />
        <span>Loading mind map...</span>
      </div>
    );
  }

  if (activeProgress) {
    return (
      <div className="h-full flex flex-col items-center justify-center gap-4 p-8 text-center">
        <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary/10 text-primary">
          <Loader2 size={24} className="animate-spin" />
        </div>
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">
            {activeProgress.message || "Generating mind map"}
          </p>
          <p className="text-xs text-muted-foreground">{Math.round(activeProgress.progress * 100)}%</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="h-full flex flex-col items-center justify-center gap-4 p-8 text-center">
        <div className="flex h-14 w-14 items-center justify-center rounded-full bg-destructive/10 text-destructive">
          <AlertCircle size={24} />
        </div>
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">Mind map failed</p>
          <p className="text-xs text-muted-foreground">{error}</p>
        </div>
        <Button onClick={handleGenerate} variant="secondary">
          Retry
        </Button>
      </div>
    );
  }

  if (result?.status === "not_applicable") {
    return (
      <div className="h-full flex flex-col items-center justify-center gap-4 p-8 text-center">
        <div className="flex h-14 w-14 items-center justify-center rounded-full bg-muted text-muted-foreground">
          <BookOpen size={24} />
        </div>
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">Mind map unavailable</p>
          <p className="text-xs leading-5 text-muted-foreground">
            {result.diagnostics.notes[0] || result.reason || "This material cannot produce a stable mind map."}
          </p>
        </div>
        <Button onClick={handleGenerate} variant="secondary">
          Generate Again
        </Button>
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
                Partial
              </span>
            )}
          </div>
        </div>

        <ul className="mt-4 space-y-3">
          <TreeNode node={result.map.root} />
        </ul>

        {artifact && (
          <p className="mt-4 text-[11px] text-muted-foreground">
            Artifact: {artifact.id}
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col items-center justify-center gap-4 p-8 text-center">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary/10 text-primary">
        {isCreatingTask ? <Loader2 size={28} className="animate-spin" /> : <Sparkles size={28} />}
      </div>
      <div className="space-y-1">
        <p className="text-sm font-medium text-foreground">Generate an article mind map</p>
        <p className="text-xs leading-5 text-muted-foreground">
          Build a reusable topic tree from the source content and keep it linked to the article.
        </p>
      </div>
      <Button onClick={handleGenerate} disabled={isCreatingTask}>
        Generate Mind Map
      </Button>
    </div>
  );
}
