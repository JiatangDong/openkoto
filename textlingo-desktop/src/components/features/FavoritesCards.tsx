import { BookOpen, CircleCheck, ExternalLink, Pencil, RotateCcw, Trash2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { Article, FavoriteGrammar, FavoriteVocabulary } from "../../types";
import { currentRetention, retentionBucket, type RetentionBucket } from "../../lib/srs";
import { Button } from "../ui/button";

function formatLocalDate(dateString?: string): string {
  if (!dateString) return "-";
  const date = new Date(dateString);
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleDateString("zh-CN");
}

const BUCKET_STYLES: Record<RetentionBucket, { dot: string; badge: string }> = {
  new: { dot: "bg-muted-foreground/40", badge: "bg-muted/60 text-muted-foreground" },
  strong: { dot: "bg-[var(--srs-strong)]", badge: "bg-[var(--srs-strong)]/15 text-[var(--srs-strong)]" },
  fading: { dot: "bg-[var(--srs-fading)]", badge: "bg-[var(--srs-fading)]/15 text-[var(--srs-fading)]" },
  weak: { dot: "bg-[var(--srs-weak)]", badge: "bg-[var(--srs-weak)]/15 text-[var(--srs-weak)]" },
};

/** 记忆保持率徽章(规范 §5):new 灰点;其余按保持率显示 绿/琥珀/红 + 百分比。 */
function RetentionBadge({ vocab }: { vocab: FavoriteVocabulary }) {
  const { t } = useTranslation();
  if (vocab.suspended_at) {
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-muted/60 px-2 py-0.5 text-[10px] text-muted-foreground">
        <CircleCheck size={10} />
        {t("favorites.mastered", "已掌握")}
      </span>
    );
  }
  const bucket = retentionBucket(vocab);
  const retention = currentRetention(vocab);
  const style = BUCKET_STYLES[bucket];
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[10px] ${style.badge}`}>
      <span className={`h-1.5 w-1.5 rounded-full ${style.dot}`} />
      {bucket === "new"
        ? t("favorites.retentionNew", "未学")
        : `${t("favorites.retention", "保持率")} ${Math.round((retention ?? 0) * 100)}%`}
    </span>
  );
}

export function EmptyState({
  icon,
  title,
  description,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
}) {
  return (
    <div className="flex flex-col items-center justify-center py-24 text-center">
      <div className="mb-6 rounded-full border border-border/50 bg-muted/30 p-6 text-muted-foreground/50">
        {icon}
      </div>
      <h3 className="mb-2 text-lg font-semibold text-foreground">{title}</h3>
      <p className="mx-auto max-w-xs text-sm leading-relaxed text-muted-foreground">{description}</p>
    </div>
  );
}

export function VocabularyCard({
  vocab,
  article,
  onDelete,
  onEdit,
  onToggleSuspended,
  onGoToArticle,
}: {
  vocab: FavoriteVocabulary;
  article?: Article;
  onDelete: () => void;
  onEdit?: () => void;
  onToggleSuspended?: () => void;
  onGoToArticle?: () => void;
}) {
  const { t } = useTranslation();
  const isSuspended = Boolean(vocab.suspended_at);
  return (
    <div
      className={`group relative rounded-xl border border-border/50 bg-card p-5 shadow-sm transition-all duration-300 hover:border-primary/20 hover:bg-gradient-to-br hover:from-card hover:to-primary/5 hover:shadow-md ${
        isSuspended ? "opacity-60" : ""
      }`}
    >
      <div className="mb-3 flex items-start justify-between">
        <div className="flex items-baseline gap-2">
          <span className="text-lg font-bold text-primary">{vocab.word}</span>
          {vocab.reading && <span className="font-mono text-xs text-muted-foreground/80">{vocab.reading}</span>}
        </div>
        <div className="flex gap-1 opacity-0 transition-opacity group-hover:opacity-100">
          {onGoToArticle && article && (
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7 text-muted-foreground hover:text-primary"
              onClick={onGoToArticle}
              title={article.title}
            >
              <ExternalLink size={14} />
            </Button>
          )}
          {onEdit && (
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7 text-muted-foreground hover:text-primary"
              onClick={onEdit}
              title={t("favorites.editWordTitle", "编辑单词")}
            >
              <Pencil size={14} />
            </Button>
          )}
          {onToggleSuspended && (
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7 text-muted-foreground hover:text-primary"
              onClick={onToggleSuspended}
              title={
                isSuspended
                  ? t("favorites.resumeReview", "恢复复习")
                  : t("favorites.markMastered", "标记已掌握")
              }
            >
              {isSuspended ? <RotateCcw size={14} /> : <CircleCheck size={14} />}
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon"
            className="h-7 w-7 text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
            onClick={onDelete}
          >
            <Trash2 size={14} />
          </Button>
        </div>
      </div>

      <div className="mb-3 space-y-2">
        <div className="text-sm font-medium leading-relaxed text-foreground/90">{vocab.meaning}</div>
        {vocab.usage && (
          <div className="inline-block rounded-md border border-primary/10 bg-primary/5 px-2 py-1 text-xs text-primary/80">
            {vocab.usage}
          </div>
        )}
        {vocab.explanation && <div className="line-clamp-3 text-xs text-muted-foreground">{vocab.explanation}</div>}
      </div>

      <div className="mt-2 flex items-center justify-between gap-2 rounded-md bg-muted/40 px-2 py-1 text-[11px] text-muted-foreground">
        <span>
          {t("favorites.cardDue", "到期")}: {vocab.due_date ?? "-"} · {t("favorites.cardReviews", "复习")}: {vocab.review_count ?? 0}
        </span>
        <RetentionBadge vocab={vocab} />
      </div>

      {vocab.source_article_title && (
        <div className="mt-2 flex items-center gap-1.5 truncate border-t border-border/30 pt-3 text-[10px] text-muted-foreground/60">
          <BookOpen size={10} />
          <span className="truncate">
            {article ? (
              vocab.source_article_title
            ) : (
              <span className="line-through decoration-muted-foreground/50 opacity-70">{vocab.source_article_title} (已删除)</span>
            )}
          </span>
        </div>
      )}
    </div>
  );
}

export function GrammarCard({
  grammar,
  article,
  onDelete,
  onGoToArticle,
}: {
  grammar: FavoriteGrammar;
  article?: Article;
  onDelete: () => void;
  onGoToArticle?: () => void;
}) {
  return (
    <div className="group relative rounded-xl border border-border/60 bg-card p-5 shadow-sm transition-all duration-300 hover:border-primary/20 hover:bg-primary/[0.02] hover:shadow-md">
      <div className="absolute bottom-4 left-0 top-4 w-1 rounded-r-lg bg-primary/40 transition-colors group-hover:bg-primary"></div>
      <div className="flex items-start justify-between gap-4 pl-4">
        <div className="flex-1 space-y-2">
          <h5 className="text-base font-bold text-foreground">{grammar.point}</h5>
          <p className="text-sm leading-relaxed text-muted-foreground">{grammar.explanation}</p>
          {grammar.example && (
            <div className="relative mt-3 rounded-lg border border-border/50 bg-muted/30 p-3 text-sm italic text-foreground/80">
              <span className="relative z-10">{grammar.example}</span>
            </div>
          )}
        </div>

        <div className="flex flex-col gap-1 opacity-0 transition-opacity group-hover:opacity-100">
          {onGoToArticle && article && (
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8 text-muted-foreground hover:text-primary"
              onClick={onGoToArticle}
              title={article.title}
            >
              <ExternalLink size={16} />
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
            onClick={onDelete}
          >
            <Trash2 size={16} />
          </Button>
        </div>
      </div>

      {grammar.source_article_title && (
        <div className="mt-4 flex items-center gap-1.5 border-t border-border/30 pl-4 pt-3 text-[10px] text-muted-foreground/60">
          <BookOpen size={10} />
          <span>
            {article ? (
              grammar.source_article_title
            ) : (
              <span className="line-through decoration-muted-foreground/50 opacity-70">{grammar.source_article_title} (已删除)</span>
            )}
          </span>
        </div>
      )}
      <div className="mt-2 pl-4 text-[11px] text-muted-foreground">收藏时间: {formatLocalDate(grammar.created_at)}</div>
    </div>
  );
}
