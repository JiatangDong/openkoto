import fs from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { parseMindMapResult } from "./mindMapSchema";

const skillDir = path.resolve(
  __dirname,
  "../.claude/skills/generate-mindmap",
);

describe("mind map schema", () => {
  it("accepts applicable results", () => {
    const result = parseMindMapResult({
      status: "applicable",
      reason: null,
      map: {
        version: "1",
        article_id: "article-1",
        title: "Sample",
        display_language: "zh-CN",
        generation_mode: "evidence_first",
        source_hash: "sha256:abc",
        summary: "Overview",
        root: {
          id: "root",
          title: "Root",
          node_type: "root",
          summary: "Summary",
          confidence: 0.9,
          source_segment_ids: ["seg-1"],
          source_offsets: [{ start: 0, end: 10 }],
          children: [],
        },
      },
      diagnostics: {
        content_type: "narrative",
        coverage: "full",
        notes: [],
        window_count: 1,
        evidence_density: 1,
        low_confidence_node_ids: [],
      },
    });

    expect(result.status).toBe("applicable");
  });

  it("accepts partial and not_applicable results", () => {
    expect(
      parseMindMapResult({
        status: "partial",
        reason: "too_long_partial_only",
        map: {
          version: "1",
          article_id: "article-1",
          title: "Sample",
          display_language: "zh-CN",
          generation_mode: "evidence_first",
          source_hash: "sha256:abc",
          summary: "Overview",
          root: {
            id: "root",
            title: "Root",
            node_type: "root",
            summary: "Summary",
            confidence: 0.7,
            source_segment_ids: [],
            source_offsets: [],
            children: [],
          },
        },
        diagnostics: {
          content_type: "dialogue",
          coverage: "partial",
          notes: ["Only high-level themes were included"],
          window_count: 8,
          evidence_density: 0.5,
          low_confidence_node_ids: ["node-1"],
        },
      }).status,
    ).toBe("partial");

    expect(
      parseMindMapResult({
        status: "not_applicable",
        reason: "music_only",
        map: null,
        diagnostics: {
          content_type: "music_only",
          coverage: "none",
          notes: ["No stable semantic content detected"],
          window_count: 1,
          evidence_density: 0,
          low_confidence_node_ids: [],
        },
      }).status,
    ).toBe("not_applicable");
  });

  it("rejects invalid confidence and missing root", () => {
    expect(() =>
      parseMindMapResult({
        status: "applicable",
        reason: null,
        map: {
          version: "1",
          article_id: "article-1",
          title: "Sample",
          display_language: "zh-CN",
          generation_mode: "evidence_first",
          source_hash: "sha256:abc",
          summary: "Overview",
        },
        diagnostics: {
          content_type: "narrative",
          coverage: "full",
          notes: [],
          window_count: 1,
          evidence_density: 1,
          low_confidence_node_ids: [],
        },
      }),
    ).toThrow();

    expect(() =>
      parseMindMapResult({
        status: "applicable",
        reason: null,
        map: {
          version: "1",
          article_id: "article-1",
          title: "Sample",
          display_language: "zh-CN",
          generation_mode: "evidence_first",
          source_hash: "sha256:abc",
          summary: "Overview",
          root: {
            id: "root",
            title: "Root",
            node_type: "root",
            summary: "Summary",
            confidence: 1.5,
            source_segment_ids: [],
            source_offsets: [],
            children: [],
          },
        },
        diagnostics: {
          content_type: "narrative",
          coverage: "full",
          notes: [],
          window_count: 1,
          evidence_density: 1,
          low_confidence_node_ids: [],
        },
      }),
    ).toThrow(/confidence/i);
  });

  it("requires the skill and schema files to exist", () => {
    expect(fs.existsSync(path.join(skillDir, "SKILL.md"))).toBe(true);
    expect(
      fs.existsSync(path.join(skillDir, "schemas", "mind-map.schema.json")),
    ).toBe(true);
    expect(
      fs.existsSync(path.join(skillDir, "prompts", "evidence-first.md")),
    ).toBe(true);
    expect(
      fs.existsSync(path.join(skillDir, "prompts", "not-applicable.md")),
    ).toBe(true);
  });
});
