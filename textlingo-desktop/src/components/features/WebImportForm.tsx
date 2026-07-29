import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useTranslation } from "react-i18next";
import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { Textarea } from "../ui/textarea";
import { Loader2, Globe, Check, Eye, Sparkles, FileText, RotateCcw, AlertTriangle } from "lucide-react";
import { getApiClient } from "../../lib/api";
import { Article } from "../../types";

interface WebImportFormProps {
  onSave?: (article: Article) => void;
  onCancel: () => void;
}

interface FetchedContent {
  title: string;
  content: string;
}

interface CleanedWebContent {
  title: string;
  content: string;
  removed_lines: number;
  removed_chars: number;
  kept_lines: number;
  partial: boolean;
}

type ImportMode = "classic" | "smart";

/** 后端用固定错误码回报可预期的清洗失败，这里翻成本地化文案 */
const CLEAN_ERROR_KEYS: Record<string, string> = {
  WEB_CLEAN_NO_CONTENT: "webImport.errors.cleanNoContent",
  WEB_CLEAN_TOO_SHORT: "webImport.errors.cleanTooShort",
  WEB_CLEAN_FAILED: "webImport.errors.cleanFailed",
};

export function WebImportForm({ onSave, onCancel }: WebImportFormProps) {
  const { t } = useTranslation();
  const [url, setUrl] = useState("");
  const [title, setTitle] = useState("");
  const [content, setContent] = useState("");
  const [isFetching, setIsFetching] = useState(false);
  const [isImporting, setIsImporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [previewLoaded, setPreviewLoaded] = useState(false);
  const [fetchSource, setFetchSource] = useState<"local" | "backend" | null>(null);

  const [mode, setMode] = useState<ImportMode>("classic");
  const [aiReady, setAiReady] = useState(false);
  // 保留经典模式的抓取结果，切回经典模式或清洗失败时可以还原
  const [rawTitle, setRawTitle] = useState("");
  const [rawContent, setRawContent] = useState("");
  const [isCleaning, setIsCleaning] = useState(false);
  const [cleanProgress, setCleanProgress] = useState<{ done: number; total: number } | null>(null);
  const [cleanResult, setCleanResult] = useState<CleanedWebContent | null>(null);
  const [showingRaw, setShowingRaw] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const config = (await invoke("get_config")) as any;
        const ready = !!(config?.model_configs?.length > 0 && config?.active_model_id);
        if (!cancelled) setAiReady(ready);
      } catch {
        if (!cancelled) setAiReady(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const isValidUrl = (value: string) =>
    value.startsWith("http://") || value.startsWith("https://");

  const isBusy = isFetching || isCleaning || isImporting;
  const canImport = !!previewLoaded && content.trim().length >= 10 && isValidUrl(url.trim());

  const describeCleanError = (err: unknown) => {
    const raw = String(err);
    const matched = Object.entries(CLEAN_ERROR_KEYS).find(([code]) => raw.includes(code));
    if (matched) return t(matched[1]);
    return t("webImport.errors.cleanGeneric", { message: raw });
  };

  const fetchWithLocalFirst = async (sourceUrl: string): Promise<FetchedContent> => {
    try {
      const local = await invoke<FetchedContent>("fetch_url_content", { url: sourceUrl });
      setFetchSource("local");
      return local;
    } catch (localErr) {
      const config = (await invoke("get_config")) as any;
      const apiClient = getApiClient(config);
      if (!apiClient.isBackendConfigured()) {
        throw localErr;
      }

      const backend = await apiClient.fetchUrlContent(sourceUrl);
      setFetchSource("backend");
      return backend;
    }
  };

  /** 在经典抓取结果上再跑一遍模型清洗，只删无关行，不改写原文 */
  const runSmartClean = async (sourceTitle: string, sourceContent: string) => {
    if (sourceContent.trim().length < 10) return;

    setIsCleaning(true);
    setError(null);
    setCleanResult(null);
    setShowingRaw(false);
    setCleanProgress(null);

    const eventId = crypto.randomUUID();
    let unlisten: (() => void) | null = null;

    try {
      unlisten = await listen<{ done: number; total: number }>(
        `web-clean://${eventId}`,
        (event) => setCleanProgress(event.payload)
      );

      const cleaned = await invoke<CleanedWebContent>("clean_web_content_cmd", {
        title: sourceTitle || undefined,
        content: sourceContent,
        eventId,
      });

      setTitle(cleaned.title || sourceTitle);
      setContent(cleaned.content);
      setCleanResult(cleaned);
    } catch (err) {
      // 清洗失败不丢内容，退回经典模式的抓取结果
      setTitle(sourceTitle);
      setContent(sourceContent);
      setError(describeCleanError(err));
    } finally {
      unlisten?.();
      setCleanProgress(null);
      setIsCleaning(false);
    }
  };

  const handleModeChange = async (next: ImportMode) => {
    if (next === mode || isBusy) return;
    setMode(next);
    setError(null);

    if (next === "classic") {
      setCleanResult(null);
      setShowingRaw(false);
      if (previewLoaded) {
        setTitle(rawTitle);
        setContent(rawContent);
      }
      return;
    }

    if (previewLoaded && rawContent && aiReady) {
      await runSmartClean(rawTitle, rawContent);
    }
  };

  const handleFetchPreview = async () => {
    const normalizedUrl = url.trim();
    if (!normalizedUrl) {
      setError(t("webImport.errors.urlRequired"));
      return;
    }
    if (!isValidUrl(normalizedUrl)) {
      setError(t("webImport.errors.urlInvalid"));
      return;
    }

    setIsFetching(true);
    setError(null);
    setPreviewLoaded(false);
    setFetchSource(null);
    setCleanResult(null);
    setShowingRaw(false);

    try {
      const fetched = await fetchWithLocalFirst(normalizedUrl);
      const nextTitle = fetched.title?.trim() || "";
      const nextContent = fetched.content?.trim() || "";

      setRawTitle(nextTitle);
      setRawContent(nextContent);
      setTitle(nextTitle);
      setContent(nextContent);
      setPreviewLoaded(true);

      if (nextContent.length < 10) {
        setError(t("webImport.errors.contentTooShort"));
        return;
      }

      if (mode === "smart" && aiReady) {
        await runSmartClean(nextTitle, nextContent);
      }
    } catch (err) {
      setError(String(err));
    } finally {
      setIsFetching(false);
    }
  };

  const handleToggleRaw = () => {
    if (!cleanResult) return;
    if (showingRaw) {
      setTitle(cleanResult.title || rawTitle);
      setContent(cleanResult.content);
      setShowingRaw(false);
    } else {
      setTitle(rawTitle);
      setContent(rawContent);
      setShowingRaw(true);
    }
  };

  const handleImport = async () => {
    const normalizedUrl = url.trim();
    if (!canImport) {
      setError(t("webImport.errors.contentTooShort"));
      return;
    }

    setIsImporting(true);
    setError(null);
    try {
      const article = await invoke<Article>("import_web_material_cmd", {
        url: normalizedUrl,
        title: title.trim() || undefined,
        content,
      });
      onSave?.(article);
    } catch (err) {
      setError(String(err));
    } finally {
      setIsImporting(false);
    }
  };

  const modes: { value: ImportMode; label: string; icon: typeof FileText }[] = [
    { value: "classic", label: t("webImport.modes.classic"), icon: FileText },
    { value: "smart", label: t("webImport.modes.smart"), icon: Sparkles },
  ];

  return (
    <div className="flex flex-col h-full">
      <div className="flex-1 space-y-4 overflow-y-auto pr-1">
        {error && (
          <div className="p-3 bg-red-900/30 border border-red-700 rounded-lg text-red-300 text-sm break-words">
            {error}
          </div>
        )}

        <div>
          <div className="inline-flex p-1 rounded-lg bg-muted/50 border border-border">
            {modes.map((item) => {
              const Icon = item.icon;
              const active = mode === item.value;
              return (
                <button
                  key={item.value}
                  type="button"
                  onClick={() => handleModeChange(item.value)}
                  disabled={isBusy}
                  aria-pressed={active}
                  className={`flex items-center gap-1.5 px-3 py-1.5 text-sm rounded-md transition-colors disabled:opacity-50 ${
                    active
                      ? "bg-background text-foreground shadow-sm"
                      : "text-muted-foreground hover:text-foreground"
                  }`}
                >
                  <Icon size={14} />
                  {item.label}
                </button>
              );
            })}
          </div>
          <p className="text-xs text-muted-foreground mt-2">
            {mode === "classic" ? t("webImport.modes.classicHint") : t("webImport.modes.smartHint")}
          </p>
          {mode === "smart" && !aiReady && (
            <p className="flex items-start gap-1.5 text-xs text-amber-500 mt-2">
              <AlertTriangle size={13} className="shrink-0 mt-0.5" />
              {t("webImport.modes.smartUnavailable")}
            </p>
          )}
        </div>

        <div className="flex gap-3 p-3 bg-blue-500/10 border border-blue-500/20 rounded-lg text-sm text-foreground/90">
          <Globe className="w-5 h-5 shrink-0 text-blue-500 mt-0.5" />
          <p>{t("webImport.hint")}</p>
        </div>

        <div>
          <label className="block text-sm font-medium text-foreground mb-2">
            {t("webImport.urlLabel")}
          </label>
          <div className="flex gap-2">
            <Input
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder={t("webImport.urlPlaceholder")}
              disabled={isBusy}
            />
            <Button onClick={handleFetchPreview} disabled={isBusy} className="gap-2">
              {isFetching ? <Loader2 size={16} className="animate-spin" /> : <Eye size={16} />}
              {isFetching ? t("webImport.fetching") : t("webImport.fetchPreview")}
            </Button>
          </div>
          {fetchSource && (
            <p className="text-xs text-muted-foreground mt-2">
              {fetchSource === "local"
                ? t("webImport.previewSourceLocal")
                : t("webImport.previewSourceBackend")}
            </p>
          )}
        </div>

        {isCleaning && (
          <div className="flex items-center gap-2 p-3 rounded-lg bg-primary/10 border border-primary/20 text-sm text-foreground/90">
            <Loader2 size={16} className="animate-spin text-primary shrink-0" />
            {cleanProgress && cleanProgress.total > 1
              ? t("webImport.clean.progress", {
                  done: cleanProgress.done,
                  total: cleanProgress.total,
                })
              : t("webImport.clean.running")}
          </div>
        )}

        {!isCleaning && cleanResult && (
          <div className="p-3 rounded-lg bg-primary/10 border border-primary/20 text-sm space-y-2">
            <div className="flex items-start gap-2">
              <Sparkles size={16} className="text-primary shrink-0 mt-0.5" />
              <div className="flex-1">
                <p className="text-foreground/90">
                  {cleanResult.removed_lines > 0
                    ? t("webImport.clean.summary", {
                        lines: cleanResult.removed_lines,
                        chars: cleanResult.removed_chars,
                      })
                    : t("webImport.clean.nothingRemoved")}
                </p>
                {cleanResult.partial && (
                  <p className="text-xs text-amber-500 mt-1">{t("webImport.clean.partial")}</p>
                )}
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              {cleanResult.removed_lines > 0 && (
                <Button variant="secondary" size="sm" className="gap-1.5" onClick={handleToggleRaw}>
                  <FileText size={14} />
                  {showingRaw ? t("webImport.clean.showCleaned") : t("webImport.clean.showRaw")}
                </Button>
              )}
              <Button
                variant="secondary"
                size="sm"
                className="gap-1.5"
                onClick={() => runSmartClean(rawTitle, rawContent)}
                disabled={isBusy}
              >
                <RotateCcw size={14} />
                {t("webImport.clean.retry")}
              </Button>
            </div>
          </div>
        )}

        <div>
          <label className="block text-sm font-medium text-foreground mb-2">
            {t("webImport.titleLabel")}
          </label>
          <Input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder={t("webImport.titlePlaceholder")}
            disabled={isImporting}
          />
        </div>

        <div>
          <div className="flex items-center justify-between mb-2">
            <label className="block text-sm font-medium text-foreground">
              {showingRaw ? t("webImport.contentLabelRaw") : t("webImport.contentLabel")}
            </label>
            <span className="text-xs text-muted-foreground">
              {t("webImport.wordCount", { count: content.trim().length })}
            </span>
          </div>
          <Textarea
            value={content}
            onChange={(e) => setContent(e.target.value)}
            placeholder={t("webImport.contentPlaceholder")}
            className="min-h-[220px]"
            disabled={isImporting}
          />
        </div>
      </div>

      <div className="flex justify-end gap-3 mt-6 pt-4 border-t border-border">
        <Button variant="secondary" onClick={onCancel} disabled={isBusy}>
          {t("common.cancel")}
        </Button>
        <Button onClick={handleImport} disabled={!canImport || isBusy} className="gap-2">
          {isImporting ? (
            <>
              <Loader2 size={16} className="animate-spin" />
              {t("webImport.importing")}
            </>
          ) : (
            <>
              <Check size={16} />
              {t("webImport.import")}
            </>
          )}
        </Button>
      </div>
    </div>
  );
}
