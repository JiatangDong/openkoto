import { useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { save } from "@tauri-apps/plugin-dialog";
import { useTranslation } from "react-i18next";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../ui/tabs";
import { Button } from "../ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "../ui/dialog";
import { Input } from "../ui/input";
import { ArrowLeft, BookOpen, Loader2, SpellCheck, Upload } from "lucide-react";
import type { Article, FavoriteGrammar, FavoriteVocabulary, WordPack } from "../../types";
import { EmptyState, GrammarCard, VocabularyCard } from "./FavoritesCards";
import { WordPackManager } from "./WordPackManager";
import { WordRecitePanel } from "./WordRecitePanel";

interface FavoritesPageProps {
  onBack: () => void;
  onSelectArticle: (article: Article) => void;
}

interface ExportWordPackResult {
  file_name: string;
  json_content: string;
}

interface ImportWordPackResult {
  created_pack_id: string;
  total: number;
  imported: number;
  skipped: number;
  errors: string[];
}

export function FavoritesPage({ onBack, onSelectArticle }: FavoritesPageProps) {
  const { t } = useTranslation();
  const [vocabularies, setVocabularies] = useState<FavoriteVocabulary[]>([]);
  const [grammars, setGrammars] = useState<FavoriteGrammar[]>([]);
  const [packs, setPacks] = useState<WordPack[]>([]);
  const [activeTab, setActiveTab] = useState("vocabulary");
  const [isLoading, setIsLoading] = useState(false);
  const [selectedPackId, setSelectedPackId] = useState("all");
  const [articles, setArticles] = useState<Map<string, Article>>(new Map());
  const [copiedPackId, setCopiedPackId] = useState<string | null>(null);
  const [isReciteOpen, setIsReciteOpen] = useState(false);
  const [isCreatePackOpen, setIsCreatePackOpen] = useState(false);
  const [newPackName, setNewPackName] = useState("");
  const [isCreatingPack, setIsCreatingPack] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const getPackName = (packId: string) => {
    if (packId === "all") return t("favorites.allPacks", "全部单词");
    return packs.find((pack) => pack.id === packId)?.name ?? t("favorites.unknownPack", "未知合集");
  };

  const selectedPackName = useMemo(
    () => getPackName(selectedPackId),
    [selectedPackId, packs, t]
  );

  const vocabularyCountByPack = useMemo(() => {
    const map = new Map<string, number>();
    for (const vocab of vocabularies) {
      for (const packId of vocab.pack_ids ?? []) {
        map.set(packId, (map.get(packId) ?? 0) + 1);
      }
    }
    return map;
  }, [vocabularies]);

  const filteredVocabularies = useMemo(() => {
    if (selectedPackId === "all") return vocabularies;
    return vocabularies.filter((vocab) => vocab.pack_ids?.includes(selectedPackId));
  }, [selectedPackId, vocabularies]);

  const getVocabulariesForPack = (packId: string) => {
    if (packId === "all") return vocabularies;
    return vocabularies.filter((vocab) => vocab.pack_ids?.includes(packId));
  };

  const loadFavorites = async () => {
    setIsLoading(true);
    try {
      const [vocabList, grammarList, packList] = await Promise.all([
        invoke<FavoriteVocabulary[]>("list_favorite_vocabularies_cmd"),
        invoke<FavoriteGrammar[]>("list_favorite_grammars_cmd"),
        invoke<WordPack[]>("list_word_packs_cmd"),
      ]);

      setVocabularies(vocabList);
      setGrammars(grammarList);
      setPacks(packList);

      const articleIds = new Set<string>();
      vocabList.forEach((v) => v.source_article_id && articleIds.add(v.source_article_id));
      grammarList.forEach((g) => g.source_article_id && articleIds.add(g.source_article_id));

      const map = new Map<string, Article>();
      for (const id of articleIds) {
        try {
          const article = await invoke<Article>("get_article", { id });
          map.set(id, article);
        } catch {
          // ignore deleted article
        }
      }
      setArticles(map);
    } catch (error) {
      console.error("Failed to load favorites:", error);
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    void loadFavorites();
  }, []);

  useEffect(() => {
    if (selectedPackId === "all") return;
    if (!packs.some((pack) => pack.id === selectedPackId)) {
      setSelectedPackId("all");
    }
  }, [packs, selectedPackId]);

  const handleDeleteVocabulary = async (id: string) => {
    try {
      await invoke("delete_favorite_vocabulary_cmd", { id });
      setVocabularies((prev) => prev.filter((item) => item.id !== id));
    } catch (error) {
      console.error("Failed to delete vocabulary:", error);
    }
  };

  const handleDeleteGrammar = async (id: string) => {
    try {
      await invoke("delete_favorite_grammar_cmd", { id });
      setGrammars((prev) => prev.filter((item) => item.id !== id));
    } catch (error) {
      console.error("Failed to delete grammar:", error);
    }
  };

  const handleGoToArticle = (articleId: string) => {
    const article = articles.get(articleId);
    if (article) {
      onSelectArticle(article);
    }
  };

  const handleCreatePack = async () => {
    const trimmedName = newPackName.trim();
    if (!trimmedName) return;
    try {
      setIsCreatingPack(true);
      await invoke<WordPack>("create_word_pack_cmd", {
        name: trimmedName,
        description: null,
        coverUrl: null,
        author: null,
        languageFrom: null,
        languageTo: null,
        tags: [],
        version: "1.0.0",
      });
      setNewPackName("");
      setIsCreatePackOpen(false);
      await loadFavorites();
    } catch (error) {
      console.error("Failed to create pack:", error);
    } finally {
      setIsCreatingPack(false);
    }
  };

  const handleDeletePack = async (pack: WordPack) => {
    if (!window.confirm(t("favorites.deletePackConfirm", `确定删除合集「${pack.name}」吗？`))) {
      return;
    }
    try {
      await invoke("delete_word_pack_cmd", { id: pack.id });
      await loadFavorites();
    } catch (error) {
      console.error("Failed to delete pack:", error);
    }
  };

  const getPlainTextExport = (packId: string): string => getVocabulariesForPack(packId).map((v) => v.word).join("\n");

  const handleCopyToClipboard = async (packId: string) => {
    if (getVocabulariesForPack(packId).length === 0) return;
    try {
      await navigator.clipboard.writeText(getPlainTextExport(packId));
      setCopiedPackId(packId);
      setTimeout(() => {
        setCopiedPackId((currentPackId) => (currentPackId === packId ? null : currentPackId));
      }, 1500);
    } catch (error) {
      console.error("Failed to copy:", error);
    }
  };

  const handleDownloadTxt = async (packId: string) => {
    if (getVocabulariesForPack(packId).length === 0) return;
    const defaultPath = `${getPackName(packId)}.txt`;
    const filePath = await save({
      defaultPath,
      filters: [{ name: "TXT", extensions: ["txt"] }],
    });
    if (!filePath) return;
    try {
      await invoke("write_text_file", { path: filePath, content: getPlainTextExport(packId) });
    } catch (error) {
      console.error("Failed to write txt file:", error);
    }
  };

  const handleExportWordPack = async (packId: string) => {
    try {
      const result = await invoke<ExportWordPackResult>("export_word_pack_cmd", {
        packId,
      });
      const filePath = await save({
        defaultPath: result.file_name,
        filters: [{ name: "OpenKoto Pack", extensions: ["okpack.json", "json"] }],
      });
      if (!filePath) return;
      await invoke("write_text_file", { path: filePath, content: result.json_content });
    } catch (error) {
      console.error("Failed to export word pack:", error);
    }
  };

  const handleImportWordPack = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = async (e) => {
      try {
        const jsonContent = String(e.target?.result ?? "");
        const result = await invoke<ImportWordPackResult>("import_word_pack_cmd", { jsonContent });
        await loadFavorites();
        alert(
          t(
            "favorites.importPackSuccess",
            `导入完成：导入/关联 ${result.imported}，跳过 ${result.skipped}，总数 ${result.total}`
          )
        );
      } catch (error) {
        console.error("Failed to import word pack:", error);
        const detail =
          typeof error === "string"
            ? error
            : error instanceof Error
              ? error.message
              : String(error);
        alert(t("favorites.importErrorWithDetail", "导入失败：{{detail}}", { detail }));
      }
    };
    reader.readAsText(file);
    event.target.value = "";
  };

  return (
    <div className="h-full max-w-6xl mx-auto p-8 flex flex-col bg-background/50">
      <div className="flex items-center gap-4 mb-8">
        <Button variant="ghost" size="icon" onClick={onBack}>
          <ArrowLeft size={20} />
        </Button>
        <div>
          <h2 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-primary to-primary/60">
            {t("favorites.title", "我的收藏")}
          </h2>
          <p className="text-sm text-muted-foreground/80 mt-1">
            {t("favorites.subtitle", "管理您收藏的单词与语法")}
          </p>
        </div>
      </div>

      <Tabs value={activeTab} onValueChange={setActiveTab} className="flex-1 flex flex-col space-y-6">
        <TabsList className="w-fit bg-muted/50 border border-border/50 p-1">
          <TabsTrigger value="vocabulary" className="gap-2 px-4">
            <BookOpen size={14} />
            {t("favorites.vocabulary", "单词收藏")}
            <span className="text-xs opacity-70 ml-1">{vocabularies.length}</span>
          </TabsTrigger>
          <TabsTrigger value="grammar" className="gap-2 px-4">
            <SpellCheck size={14} />
            {t("favorites.grammar", "语法收藏")}
            <span className="text-xs opacity-70 ml-1">{grammars.length}</span>
          </TabsTrigger>
        </TabsList>

        {isLoading ? (
          <div className="flex items-center justify-center py-20">
            <Loader2 className="animate-spin text-primary" size={32} />
          </div>
        ) : (
          <div className="flex-1 overflow-y-auto pr-2 min-h-0">
            <TabsContent value="vocabulary" className="mt-0 h-full flex flex-col">
              <div className="mb-5 flex justify-end">
                <input
                  ref={fileInputRef}
                  className="hidden"
                  type="file"
                  accept=".json,.okpack.json"
                  onChange={handleImportWordPack}
                />
                <Button variant="outline" size="sm" className="gap-2" onClick={() => fileInputRef.current?.click()}>
                  <Upload size={16} />
                  {t("favorites.importWordPack", "导入单词包")}
                </Button>
              </div>

              <div className="flex gap-4 min-h-0 pb-8">
                <WordPackManager
                  packs={packs}
                  selectedPackId={selectedPackId}
                  vocabularyCountByPack={vocabularyCountByPack}
                  copiedPackId={copiedPackId}
                  onSelectPack={setSelectedPackId}
                  onCreatePack={() => setIsCreatePackOpen(true)}
                  onCopyWords={(packId) => void handleCopyToClipboard(packId)}
                  onDownloadTxt={(packId) => void handleDownloadTxt(packId)}
                  onExportWordPack={(packId) => void handleExportWordPack(packId)}
                  onDeletePack={(pack) => void handleDeletePack(pack)}
                  onStartReview={() => setIsReciteOpen(true)}
                />

                <div className="flex-1">
                  {filteredVocabularies.length === 0 ? (
                    <EmptyState
                      icon={<BookOpen size={48} />}
                      title={t("favorites.noVocabulary", "暂无单词收藏")}
                      description={t("favorites.noVocabularyDesc", "在文章学习中点击单词旁的收藏按钮即可添加")}
                    />
                  ) : (
                    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                      {filteredVocabularies.map((vocab) => (
                        <VocabularyCard
                          key={vocab.id}
                          vocab={vocab}
                          article={vocab.source_article_id ? articles.get(vocab.source_article_id) : undefined}
                          onDelete={() => void handleDeleteVocabulary(vocab.id)}
                          onGoToArticle={
                            vocab.source_article_id
                              ? () => handleGoToArticle(vocab.source_article_id as string)
                              : undefined
                          }
                        />
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </TabsContent>

            <TabsContent value="grammar" className="mt-0 h-full flex flex-col">
              {grammars.length === 0 ? (
                <EmptyState
                  icon={<SpellCheck size={48} />}
                  title={t("favorites.noGrammar", "暂无语法收藏")}
                  description={t("favorites.noGrammarDesc", "在文章学习中点击语法点旁的收藏按钮即可添加")}
                />
              ) : (
                <div className="space-y-4 pb-8">
                  {grammars.map((grammar) => (
                    <GrammarCard
                      key={grammar.id}
                      grammar={grammar}
                      article={grammar.source_article_id ? articles.get(grammar.source_article_id) : undefined}
                      onDelete={() => void handleDeleteGrammar(grammar.id)}
                      onGoToArticle={
                        grammar.source_article_id
                          ? () => handleGoToArticle(grammar.source_article_id as string)
                          : undefined
                      }
                    />
                  ))}
                </div>
              )}
            </TabsContent>
          </div>
        )}
      </Tabs>

      <WordRecitePanel
        open={isReciteOpen}
        onOpenChange={setIsReciteOpen}
        packId={selectedPackId}
        packName={selectedPackName}
        onReviewed={loadFavorites}
      />

      <Dialog
        open={isCreatePackOpen}
        onOpenChange={(open) => {
          setIsCreatePackOpen(open);
          if (!open) {
            setNewPackName("");
          }
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t("favorites.newPackTitle", "新建单词合集")}</DialogTitle>
          </DialogHeader>
          <Input
            value={newPackName}
            onChange={(event) => setNewPackName(event.target.value)}
            placeholder={t("favorites.newPackPrompt", "输入新合集名称")}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                void handleCreatePack();
              }
            }}
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setIsCreatePackOpen(false)}>
              {t("common.cancel", "取消")}
            </Button>
            <Button disabled={isCreatingPack || !newPackName.trim()} onClick={() => void handleCreatePack()}>
              {t("common.create", "创建")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
