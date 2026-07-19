// FSRS 保持率(retrievability)只读镜像 — 仅用于 UI 标色/展示,不做调度。
// 调度算法在 Rust 侧(src-tauri/src/fsrs.rs);公式与常量以规范为准:
// docs/specs/vocabulary-srs-spec.md §2.3 / §5,黄金用例 docs/specs/fixtures/fsrs_golden_v1.json。

import type { FavoriteVocabulary } from "../types";

/** ts-fsrs 5.4.1 default_w 的 w20(decay 参数) */
const W20 = 0.1542;
const DECAY = -W20;
/** round8(0.9^(1/decay) - 1),与规范 §2.2 一致 */
const FACTOR = Math.round((Math.pow(0.9, 1 / DECAY) - 1) * 1e8) / 1e8;

const DAY_MS = 24 * 60 * 60 * 1000;

/** R(t, S):t 为距上次复习的天数(可为小数);stability<=0 视为无记忆(0)。 */
export function retrievability(stability: number, elapsedDays: number): number {
  if (stability <= 0) return 0;
  const r = Math.pow(1 + (FACTOR * elapsedDays) / stability, DECAY);
  return Math.round(r * 1e8) / 1e8;
}

export type RetentionBucket = "new" | "strong" | "fading" | "weak";

/** 保持率分档(规范 §5):new 卡一律 "new";R≥0.90 强,0.70–0.90 衰减,<0.70 弱。 */
export function retentionBucket(card: FavoriteVocabulary, now: Date = new Date()): RetentionBucket {
  const stability = card.stability ?? 0;
  if ((card.srs_state ?? "new") === "new" || stability <= 0 || !card.last_reviewed_at) {
    return "new";
  }
  const last = new Date(card.last_reviewed_at);
  if (Number.isNaN(last.getTime())) return "new";
  const elapsedDays = Math.max(0, (now.getTime() - last.getTime()) / DAY_MS);
  const r = retrievability(stability, elapsedDays);
  if (r >= 0.9) return "strong";
  if (r >= 0.7) return "fading";
  return "weak";
}

/** 当前保持率(0-1);new 卡返回 null(无意义)。 */
export function currentRetention(
  card: FavoriteVocabulary,
  now: Date = new Date()
): number | null {
  const stability = card.stability ?? 0;
  if ((card.srs_state ?? "new") === "new" || stability <= 0 || !card.last_reviewed_at) {
    return null;
  }
  const last = new Date(card.last_reviewed_at);
  if (Number.isNaN(last.getTime())) return null;
  const elapsedDays = Math.max(0, (now.getTime() - last.getTime()) / DAY_MS);
  return retrievability(stability, elapsedDays);
}
