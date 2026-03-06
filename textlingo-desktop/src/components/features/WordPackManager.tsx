import { Check, Copy, Download, FileDown, MoreHorizontal, Play, Plus, Trash2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { WordPack } from "../../types";
import { Button } from "../ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from "../ui/dropdown-menu";

interface WordPackManagerProps {
  packs: WordPack[];
  selectedPackId: string;
  vocabularyCountByPack: Map<string, number>;
  copiedPackId: string | null;
  onSelectPack: (packId: string) => void;
  onCreatePack: () => void;
  onCopyWords: (packId: string) => void;
  onDownloadTxt: (packId: string) => void;
  onExportWordPack: (packId: string) => void;
  onDeletePack: (pack: WordPack) => void;
  onStartReview: () => void;
}

interface ActionMenuProps {
  packId: string;
  label: string;
  wordCount: number;
  copiedPackId: string | null;
  allowWordPackExport: boolean;
  allowDelete: boolean;
  onCopyWords: (packId: string) => void;
  onDownloadTxt: (packId: string) => void;
  onExportWordPack?: (packId: string) => void;
  onDelete?: () => void;
}

function PackActionsMenu({
  packId,
  label,
  wordCount,
  copiedPackId,
  allowWordPackExport,
  allowDelete,
  onCopyWords,
  onDownloadTxt,
  onExportWordPack,
  onDelete,
}: ActionMenuProps) {
  const { t } = useTranslation();
  const hasWords = wordCount > 0;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="h-8 w-8 shrink-0 text-muted-foreground hover:text-foreground"
          aria-label={`${label}${t("favorites.packActionsSuffix", "操作")}`}
        >
          <MoreHorizontal size={14} />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-56">
        {hasWords && (
          <>
            <DropdownMenuLabel>{t("favorites.exportWordList", "导出单词列表")}</DropdownMenuLabel>
            <DropdownMenuItem onClick={() => onCopyWords(packId)}>
              <Copy className="mr-2 h-4 w-4" />
              <span>{copiedPackId === packId ? t("favorites.copied", "已复制") : t("favorites.copyToClipboard", "复制到剪贴板")}</span>
              {copiedPackId === packId && <Check className="ml-auto h-4 w-4 text-green-500" />}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => onDownloadTxt(packId)}>
              <FileDown className="mr-2 h-4 w-4" />
              <span>{t("favorites.downloadTxt", "下载 TXT 文件")}</span>
            </DropdownMenuItem>
            {(allowWordPackExport || allowDelete) && <DropdownMenuSeparator />}
          </>
        )}

        {allowWordPackExport && onExportWordPack && (
          <DropdownMenuItem onClick={() => onExportWordPack(packId)}>
            <Download className="mr-2 h-4 w-4" />
            <span>{t("favorites.exportWordPack", "导出单词包")}</span>
          </DropdownMenuItem>
        )}

        {allowDelete && onDelete && (
          <DropdownMenuItem onClick={onDelete} className="text-destructive focus:text-destructive">
            <Trash2 className="mr-2 h-4 w-4" />
            <span>{t("favorites.deletePackAction", "删除合集")}</span>
          </DropdownMenuItem>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export function WordPackManager({
  packs,
  selectedPackId,
  vocabularyCountByPack,
  copiedPackId,
  onSelectPack,
  onCreatePack,
  onCopyWords,
  onDownloadTxt,
  onExportWordPack,
  onDeletePack,
  onStartReview,
}: WordPackManagerProps) {
  const { t } = useTranslation();
  const allWordsCount = Array.from(vocabularyCountByPack.values()).reduce((acc, curr) => acc + curr, 0);

  return (
    <div className="w-72 shrink-0 rounded-xl border border-border/50 bg-card p-3">
      <div className="mb-3 flex items-center justify-between">
        <h3 className="text-sm font-semibold">{t("favorites.packListTitle", "单词合集")}</h3>
        <Button size="sm" variant="outline" onClick={onCreatePack}>
          <Plus size={14} className="mr-1" />
          {t("favorites.newPack", "新建")}
        </Button>
      </div>

      <div className="space-y-1">
        <div className="group flex items-center gap-1">
          <button
            className={`flex flex-1 items-center justify-between rounded-md px-2 py-2 text-sm transition-colors ${
              selectedPackId === "all" ? "bg-primary/10 text-primary" : "hover:bg-muted/70"
            }`}
            onClick={() => onSelectPack("all")}
          >
            <span>{t("favorites.allPacks", "全部单词")}</span>
            <span className="text-xs text-muted-foreground">{allWordsCount}</span>
          </button>
          <PackActionsMenu
            packId="all"
            label={t("favorites.allPacks", "全部单词")}
            wordCount={allWordsCount}
            copiedPackId={copiedPackId}
            allowWordPackExport
            allowDelete={false}
            onCopyWords={onCopyWords}
            onDownloadTxt={onDownloadTxt}
            onExportWordPack={onExportWordPack}
          />
        </div>

        {packs.map((pack) => {
          const count = vocabularyCountByPack.get(pack.id) ?? 0;
          return (
            <div key={pack.id} className="group flex items-center gap-1">
              <button
                className={`flex-1 rounded-md px-2 py-2 text-left text-sm transition-colors ${
                  selectedPackId === pack.id ? "bg-primary/10 text-primary" : "hover:bg-muted/70"
                }`}
                onClick={() => onSelectPack(pack.id)}
              >
                <div className="truncate">{pack.name}</div>
                <div className="text-xs text-muted-foreground">{count} 词</div>
              </button>
              <PackActionsMenu
                packId={pack.id}
                label={pack.name}
                wordCount={count}
                copiedPackId={copiedPackId}
                allowWordPackExport
                allowDelete={!pack.is_system}
                onCopyWords={onCopyWords}
                onDownloadTxt={onDownloadTxt}
                onExportWordPack={onExportWordPack}
                onDelete={!pack.is_system ? () => onDeletePack(pack) : undefined}
              />
            </div>
          );
        })}
      </div>

      <Button className="mt-4 w-full" onClick={onStartReview}>
        <Play size={14} className="mr-2" />
        {t("favorites.startReview", "开始复习")}
      </Button>
    </div>
  );
}
