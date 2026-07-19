// Anki 可直接导入的 TSV 导出(规范决策 D12 / issue #12)。
// Anki 23+ 识别文件头指令(#separator/#html/#columns),自动映射字段。
// 释义常含逗号,故用 TSV 而非 CSV;字段内换行转 <br>,制表符转空格。

import type { FavoriteVocabulary } from "../types";

function sanitizeField(value: string | undefined): string {
  if (!value) return "";
  return value.replace(/\t/g, " ").replace(/\r?\n/g, "<br>").trim();
}

/** 列序:word, reading, meaning, example, usage(与文件头 #columns 一致)。 */
export function buildAnkiTsv(vocab: FavoriteVocabulary[]): string {
  const header = ["#separator:tab", "#html:true", "#columns:word\treading\tmeaning\texample\tusage"];
  const rows = vocab.map((item) =>
    [
      sanitizeField(item.word),
      sanitizeField(item.reading),
      sanitizeField(item.meaning),
      sanitizeField(item.example),
      sanitizeField(item.usage),
    ].join("\t")
  );
  return [...header, ...rows].join("\n") + "\n";
}
