import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import type { FavoriteVocabulary, WordPack } from "../../types";
import { Button } from "../ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "../ui/dialog";
import { Input } from "../ui/input";

export interface VocabFormValues {
  word: string;
  meaning: string;
  reading: string;
  usage: string;
  example: string;
  packIds: string[];
}

interface VocabEditDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 编辑既有卡片时传入;新增时为 undefined */
  vocab?: FavoriteVocabulary;
  /** 新增模式下用于选择词包 */
  packs: WordPack[];
  defaultPackId: string;
  onSubmit: (values: VocabFormValues) => Promise<void>;
}

/** 手动添加 / 编辑单词的共用表单(词形、释义、读音、用法、例句、词包)。 */
export function VocabEditDialog({
  open,
  onOpenChange,
  vocab,
  packs,
  defaultPackId,
  onSubmit,
}: VocabEditDialogProps) {
  const { t } = useTranslation();
  const isEdit = Boolean(vocab);
  const [word, setWord] = useState("");
  const [meaning, setMeaning] = useState("");
  const [reading, setReading] = useState("");
  const [usage, setUsage] = useState("");
  const [example, setExample] = useState("");
  const [packIds, setPackIds] = useState<string[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setWord(vocab?.word ?? "");
    setMeaning(vocab?.meaning ?? "");
    setReading(vocab?.reading ?? "");
    setUsage(vocab?.usage ?? "");
    setExample(vocab?.example ?? "");
    setPackIds(
      vocab?.pack_ids?.length
        ? vocab.pack_ids
        : defaultPackId && defaultPackId !== "all"
          ? [defaultPackId]
          : []
    );
    setError(null);
  }, [open, vocab, defaultPackId]);

  const togglePack = (packId: string) => {
    setPackIds((prev) =>
      prev.includes(packId) ? prev.filter((id) => id !== packId) : [...prev, packId]
    );
  };

  const handleSubmit = async () => {
    if (!word.trim() || !meaning.trim()) return;
    setIsSubmitting(true);
    setError(null);
    try {
      await onSubmit({
        word: word.trim(),
        meaning: meaning.trim(),
        reading: reading.trim(),
        usage: usage.trim(),
        example: example.trim(),
        packIds,
      });
      onOpenChange(false);
    } catch (err) {
      const detail = typeof err === "string" ? err : err instanceof Error ? err.message : String(err);
      setError(
        detail === "DUPLICATE_WORD"
          ? t("favorites.duplicateWordError", "已存在相同单词,请直接编辑原有卡片")
          : detail
      );
    } finally {
      setIsSubmitting(false);
    }
  };

  const field = (
    label: string,
    value: string,
    onChange: (value: string) => void,
    options?: { required?: boolean; placeholder?: string }
  ) => (
    <div>
      <label className="mb-1.5 block text-sm font-medium text-foreground">
        {label}
        {options?.required && <span className="ml-0.5 text-destructive">*</span>}
      </label>
      <Input
        value={value}
        placeholder={options?.placeholder}
        onChange={(event) => onChange(event.target.value)}
      />
    </div>
  );

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {isEdit
              ? t("favorites.editWordTitle", "编辑单词")
              : t("favorites.addWordTitle", "手动添加单词")}
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-3">
          {field(t("favorites.fieldWord", "单词"), word, setWord, { required: true })}
          {field(t("favorites.fieldMeaning", "释义"), meaning, setMeaning, { required: true })}
          {field(t("favorites.fieldReading", "读音"), reading, setReading, {
            placeholder: t("favorites.fieldReadingPlaceholder", "假名 / 拼音 / 音标(可选)"),
          })}
          {field(t("favorites.fieldUsage", "用法"), usage, setUsage, {
            placeholder: t("favorites.fieldUsagePlaceholder", "词性、搭配等(可选)"),
          })}
          {field(t("favorites.fieldExample", "例句"), example, setExample, {
            placeholder: t("favorites.fieldExamplePlaceholder", "可选"),
          })}

          {!isEdit && packs.length > 0 && (
            <div>
              <div className="mb-1.5 text-sm font-medium text-foreground">
                {t("favorites.fieldPacks", "加入合集")}
              </div>
              <div className="flex max-h-28 flex-wrap gap-2 overflow-y-auto">
                {packs.map((pack) => (
                  <button
                    key={pack.id}
                    type="button"
                    onClick={() => togglePack(pack.id)}
                    className={`rounded-full border px-3 py-1 text-xs transition-colors ${
                      packIds.includes(pack.id)
                        ? "border-primary/40 bg-primary/10 text-primary"
                        : "border-border/60 text-muted-foreground hover:bg-muted/60"
                    }`}
                  >
                    {pack.name}
                  </button>
                ))}
              </div>
            </div>
          )}

          {error && <div className="text-sm text-destructive">{error}</div>}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {t("common.cancel", "取消")}
          </Button>
          <Button
            disabled={isSubmitting || !word.trim() || !meaning.trim()}
            onClick={() => void handleSubmit()}
          >
            {isEdit ? t("common.save", "保存") : t("common.add", "添加")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
