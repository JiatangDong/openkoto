import { useTranslation } from "react-i18next";
import { Loader2, Sparkles, FileText, RotateCcw } from "lucide-react";
import { Button } from "../ui/button";
import type { CleanedWebContent } from "../../lib/hooks";

interface AiCleanPanelProps {
  isCleaning: boolean;
  progress: { done: number; total: number } | null;
  result: CleanedWebContent | null;
  showingRaw: boolean;
  onToggleRaw: () => void;
  onRetry: () => void;
  disabled?: boolean;
}

/**
 * 清洗进度与结果条。网页导入与文本新建共用——两处对"删了多少、能不能看回原文"
 * 的诉求完全一样，各写一份只会长成两种样子。
 */
export function AiCleanPanel({
  isCleaning,
  progress,
  result,
  showingRaw,
  onToggleRaw,
  onRetry,
  disabled,
}: AiCleanPanelProps) {
  const { t } = useTranslation();

  if (isCleaning) {
    return (
      <div className="flex items-center gap-2 p-3 rounded-lg bg-primary/10 border border-primary/20 text-sm text-foreground/90">
        <Loader2 size={16} className="animate-spin text-primary shrink-0" />
        {progress && progress.total > 1
          ? t("webImport.clean.progress", { done: progress.done, total: progress.total })
          : t("webImport.clean.running")}
      </div>
    );
  }

  if (!result) return null;

  return (
    <div className="p-3 rounded-lg bg-primary/10 border border-primary/20 text-sm space-y-2">
      <div className="flex items-start gap-2">
        <Sparkles size={16} className="text-primary shrink-0 mt-0.5" />
        <div className="flex-1">
          <p className="text-foreground/90">
            {result.removed_lines > 0
              ? t("webImport.clean.summary", {
                  lines: result.removed_lines,
                  chars: result.removed_chars,
                })
              : t("webImport.clean.nothingRemoved")}
          </p>
          {result.partial && (
            <p className="text-xs text-amber-500 mt-1">{t("webImport.clean.partial")}</p>
          )}
        </div>
      </div>
      <div className="flex flex-wrap gap-2">
        {result.removed_lines > 0 && (
          <Button variant="secondary" size="sm" className="gap-1.5" onClick={onToggleRaw}>
            <FileText size={14} />
            {showingRaw ? t("webImport.clean.showCleaned") : t("webImport.clean.showRaw")}
          </Button>
        )}
        <Button
          variant="secondary"
          size="sm"
          className="gap-1.5"
          onClick={onRetry}
          disabled={disabled}
        >
          <RotateCcw size={14} />
          {t("webImport.clean.retry")}
        </Button>
      </div>
    </div>
  );
}
