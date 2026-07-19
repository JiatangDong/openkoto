import { describe, expect, it } from "vitest";
import fixture from "../../../docs/specs/fixtures/fsrs_golden_v1.json";
import { retentionBucket, retrievability } from "./srs";
import type { FavoriteVocabulary } from "../types";

interface FixtureCase {
  name: string;
  reviews: { day_offset: number; grade: string }[];
  expected: { stability: number }[];
  retrievability_checks?: { after_step: number; elapsed_days: number; expected: number }[];
}

describe("retrievability", () => {
  it("matches golden fixture checks", () => {
    const cases = fixture.cases as FixtureCase[];
    const checked = cases.filter((c) => c.retrievability_checks?.length);
    expect(checked.length).toBeGreaterThan(0);
    for (const c of checked) {
      for (const check of c.retrievability_checks!) {
        const stability = c.expected[check.after_step].stability;
        expect(
          Math.abs(retrievability(stability, check.elapsed_days) - check.expected),
          `${c.name} after step ${check.after_step} at ${check.elapsed_days}d`
        ).toBeLessThan(1e-6);
      }
    }
  });

  it("returns 1 at zero elapsed and 0 for uninitialized stability", () => {
    expect(retrievability(2.3065, 0)).toBe(1);
    expect(retrievability(0, 5)).toBe(0);
  });
});

describe("retentionBucket", () => {
  const base: FavoriteVocabulary = {
    id: "x",
    word: "w",
    meaning: "m",
    usage: "u",
    created_at: "2026-07-01T00:00:00Z",
    srs_state: "review",
    stability: 10,
    last_reviewed_at: "2026-07-10T00:00:00Z",
  };
  const now = new Date("2026-07-10T00:00:00Z");

  it("classifies by retention thresholds", () => {
    // elapsed 3 天,S=10 → R≈0.96 → strong(t<S 时 R>0.9)
    expect(retentionBucket(base, new Date("2026-07-13T00:00:00Z"))).toBe("strong");
    // 30 天后 → R≈0.81 → fading
    expect(retentionBucket(base, new Date("2026-08-09T00:00:00Z"))).toBe("fading");
    // 100 天后 → R≈0.69 → weak
    expect(retentionBucket(base, new Date("2026-10-18T00:00:00Z"))).toBe("weak");
  });

  it("treats new/uninitialized cards as new", () => {
    expect(retentionBucket({ ...base, srs_state: "new" }, now)).toBe("new");
    expect(retentionBucket({ ...base, stability: 0 }, now)).toBe("new");
    expect(retentionBucket({ ...base, last_reviewed_at: undefined }, now)).toBe("new");
  });
});
