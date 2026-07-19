import { describe, expect, it } from "vitest";
import { buildAnkiTsv } from "./ankiExport";
import type { FavoriteVocabulary } from "../types";

function card(overrides: Partial<FavoriteVocabulary>): FavoriteVocabulary {
  return {
    id: "x",
    word: "word",
    meaning: "meaning",
    usage: "usage",
    created_at: "2026-07-01T00:00:00Z",
    ...overrides,
  };
}

describe("buildAnkiTsv", () => {
  it("emits Anki header directives and column order", () => {
    const tsv = buildAnkiTsv([card({ word: "犬", reading: "いぬ", meaning: "狗", example: "犬が走る" })]);
    const lines = tsv.trimEnd().split("\n");
    expect(lines[0]).toBe("#separator:tab");
    expect(lines[1]).toBe("#html:true");
    expect(lines[2]).toBe("#columns:word\treading\tmeaning\texample\tusage");
    expect(lines[3]).toBe("犬\tいぬ\t狗\t犬が走る\tusage");
  });

  it("escapes tabs and converts newlines to <br>", () => {
    const tsv = buildAnkiTsv([
      card({ word: "a\tb", meaning: "line1\nline2", example: "x\r\ny", usage: "" }),
    ]);
    const row = tsv.split("\n")[3];
    // 列序 word, reading(空), meaning, example, usage(空)
    expect(row).toBe("a b\t\tline1<br>line2\tx<br>y\t");
  });

  it("keeps commas intact (TSV, not CSV)", () => {
    const tsv = buildAnkiTsv([card({ meaning: "狗, 犬科动物" })]);
    expect(tsv).toContain("狗, 犬科动物");
  });
});
