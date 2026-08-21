import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useTranslation } from "react-i18next";

export interface CleanedWebContent {
  title: string;
  content: string;
  removed_lines: number;
  removed_chars: number;
  kept_lines: number;
  partial: boolean;
}

export interface CleanSource {
  title: string;
  content: string;
}

export type CleanOutcome =
  | ({ status: "cleaned"; result: CleanedWebContent } & CleanSource)
  | ({ status: "failed"; error: string } & CleanSource);

/** 后端用固定错误码回报可预期的清洗失败，这里翻成本地化文案 */
const CLEAN_ERROR_KEYS: Record<string, string> = {
  WEB_CLEAN_NO_CONTENT: "webImport.errors.cleanNoContent",
  WEB_CLEAN_TOO_SHORT: "webImport.errors.cleanTooShort",
  WEB_CLEAN_FAILED: "webImport.errors.cleanFailed",
};

/** 少于这个字数就没什么可清洗的，别浪费一次模型调用 */
export const CLEAN_MIN_CHARS = 10;

/**
 * AI 清洗素材正文：删掉导航、广告、推荐位、评论、页脚等无关行，**正文逐字不动**。
 *
 * 状态放在 hook 里而不是各自的表单里，是因为网页导入和文本新建要的是同一套东西：
 * 进度、失败退回原文、清洗前后对照。两份实现迟早会漂移成两种行为。
 *
 * 调用方负责 title/content 的真身；hook 只保管"清洗前那一版"用于对照与回滚——
 * 清洗把正文删没了必须是可逆的。
 */
export function useAiClean() {
  const { t } = useTranslation();
  const [aiReady, setAiReady] = useState(false);
  const [isCleaning, setIsCleaning] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [result, setResult] = useState<CleanedWebContent | null>(null);
  const [showingRaw, setShowingRaw] = useState(false);
  const rawRef = useRef<CleanSource | null>(null);

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

  const describeError = useCallback(
    (err: unknown) => {
      const raw = String(err);
      const matched = Object.entries(CLEAN_ERROR_KEYS).find(([code]) => raw.includes(code));
      if (matched) return t(matched[1]);
      return t("webImport.errors.cleanGeneric", { message: raw });
    },
    [t]
  );

  /** 丢弃上一次的清洗结果与原文快照。换了一份正文就必须调用，否则"查看原文"会贴回上一篇。 */
  const reset = useCallback(() => {
    setResult(null);
    setShowingRaw(false);
    rawRef.current = null;
  }, []);

  /** 记下这一份原文，之后 clean() 都以它为准（而不是在已清洗结果上再删一轮）。 */
  const setSource = useCallback((source: CleanSource) => {
    rawRef.current = source;
  }, []);

  const raw = useCallback(() => rawRef.current, []);

  const clean = useCallback(
    async (source: CleanSource): Promise<CleanOutcome> => {
      rawRef.current = source;
      setIsCleaning(true);
      setResult(null);
      setShowingRaw(false);
      setProgress(null);

      const eventId = crypto.randomUUID();
      let unlisten: (() => void) | null = null;

      try {
        unlisten = await listen<{ done: number; total: number }>(
          `web-clean://${eventId}`,
          (event) => setProgress(event.payload)
        );

        const cleaned = await invoke<CleanedWebContent>("clean_web_content_cmd", {
          title: source.title || undefined,
          content: source.content,
          eventId,
        });

        setResult(cleaned);
        return {
          status: "cleaned",
          result: cleaned,
          title: cleaned.title || source.title,
          content: cleaned.content,
        };
      } catch (err) {
        // 清洗失败不丢内容，退回清洗前的原文
        return { status: "failed", error: describeError(err), ...source };
      } finally {
        unlisten?.();
        setProgress(null);
        setIsCleaning(false);
      }
    },
    [describeError]
  );

  /** 在「原文 / 清洗结果」之间切换，返回应当填回编辑区的那一版。 */
  const toggleRaw = useCallback((): CleanSource | null => {
    const source = rawRef.current;
    if (!result || !source) return null;
    const next = showingRaw
      ? { title: result.title || source.title, content: result.content }
      : source;
    setShowingRaw(!showingRaw);
    return next;
  }, [result, showingRaw]);

  return {
    aiReady,
    isCleaning,
    progress,
    result,
    showingRaw,
    clean,
    toggleRaw,
    reset,
    setSource,
    raw,
  };
}
