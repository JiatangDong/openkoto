import { useTranslation } from "react-i18next";
import { UploadCloud, Loader2, CheckCircle2, AlertCircle } from "lucide-react";

export interface DropImportStatus {
  ok: number;
  errors: string[];
}

interface DropImportOverlayProps {
  isDragging: boolean;
  isImporting: boolean;
  importingCount: number;
  status: DropImportStatus | null;
}

/**
 * 全屏拖放导入提示层：拖动中显示「松开以导入」，导入中显示 spinner，
 * 完成后底部短暂显示结果。挂在 App 根容器内。
 */
export function DropImportOverlay({
  isDragging,
  isImporting,
  importingCount,
  status,
}: DropImportOverlayProps) {
  const { t } = useTranslation();

  return (
    <>
      {/* 拖动中 / 导入中：全屏蒙层 */}
      {(isDragging || isImporting) && (
        <div className="fixed inset-0 z-[90] flex items-center justify-center bg-background/80 backdrop-blur-sm p-8">
          <div className="flex flex-col items-center gap-4 rounded-2xl border-2 border-dashed border-primary bg-card/60 px-12 py-10 text-center shadow-2xl">
            {isImporting ? (
              <>
                <Loader2 size={48} className="animate-spin text-primary" />
                <p className="text-lg font-medium text-foreground">
                  {t("dropImport.importing", "正在导入 {{count}} 个文件…", { count: importingCount })}
                </p>
              </>
            ) : (
              <>
                <UploadCloud size={48} className="text-primary" />
                <p className="text-lg font-medium text-foreground">
                  {t("dropImport.hint", "松开以导入")}
                </p>
                <p className="text-sm text-muted-foreground">
                  {t("dropImport.types", "PDF / EPUB / 视频 / 音频 / 字幕")}
                </p>
              </>
            )}
          </div>
        </div>
      )}

      {/* 完成结果：底部短暂横幅 */}
      {status && !isImporting && !isDragging && (
        <div className="fixed bottom-6 left-1/2 z-[90] -translate-x-1/2">
          <div className="flex items-center gap-2 rounded-lg border border-border bg-card px-4 py-2.5 text-sm shadow-lg">
            {status.errors.length === 0 ? (
              <CheckCircle2 size={16} className="text-green-600 dark:text-green-400 shrink-0" />
            ) : (
              <AlertCircle size={16} className="text-destructive shrink-0" />
            )}
            <div className="flex flex-col">
              {status.ok > 0 && (
                <span className="text-foreground">
                  {t("dropImport.done", "已导入 {{count}} 个", { count: status.ok })}
                </span>
              )}
              {status.errors.map((e, i) => (
                <span key={i} className="text-destructive text-xs">{e}</span>
              ))}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
