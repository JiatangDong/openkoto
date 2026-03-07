import { z } from "zod";

export const mindMapNodeSchema: z.ZodType<any> = z.lazy(() =>
  z.object({
    id: z.string().min(1),
    title: z.string().min(1),
    node_type: z.enum([
      "root",
      "theme",
      "topic",
      "event",
      "entity",
      "relation",
      "evidence",
    ]),
    summary: z.string(),
    confidence: z.number().min(0).max(1),
    source_segment_ids: z.array(z.string()).default([]),
    source_offsets: z
      .array(
        z.object({
          start: z.number().int().nonnegative(),
          end: z.number().int().nonnegative(),
        }),
      )
      .default([]),
    time_range: z
      .object({
        start: z.number(),
        end: z.number(),
      })
      .optional(),
    children: z.array(mindMapNodeSchema).default([]),
  }),
);

export const mindMapResultSchema = z
  .object({
    status: z.enum(["applicable", "partial", "not_applicable"]),
    reason: z.string().nullable().optional(),
    map: z
      .object({
        version: z.string().min(1),
        article_id: z.string().min(1),
        title: z.string().min(1),
        display_language: z.string().min(1),
        generation_mode: z.string().min(1),
        source_hash: z.string().min(1),
        summary: z.string(),
        root: mindMapNodeSchema,
      })
      .nullable()
      .optional(),
    diagnostics: z.object({
      content_type: z.enum([
        "narrative",
        "lecture",
        "dialogue",
        "article",
        "lyrics",
        "music_only",
        "mixed",
        "unknown",
      ]),
      coverage: z.enum(["full", "partial", "none"]),
      notes: z.array(z.string()).default([]),
      window_count: z.number().int().nonnegative(),
      evidence_density: z.number().min(0).max(1),
      low_confidence_node_ids: z.array(z.string()).default([]),
    }),
  })
  .superRefine((value, ctx) => {
    if ((value.status === "applicable" || value.status === "partial") && !value.map) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "map is required when status is applicable or partial",
        path: ["map"],
      });
    }
    if (value.status === "not_applicable" && value.map) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "map must be null when status is not_applicable",
        path: ["map"],
      });
    }
  });

export function parseMindMapResult(value: unknown) {
  return mindMapResultSchema.parse(value);
}

