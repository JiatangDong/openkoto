// Generates the cross-platform FSRS golden fixture consumed by:
//   - textlingo-desktop/src-tauri/tests/fsrs_golden_test.rs   (Rust engine)
//   - openkoto-ios/.../Tests/OKSRSTests/FSRSGoldenTests.swift  (Swift engine)
//   - textlingo-desktop/src/lib/srs.test.ts                    (TS retrievability mirror)
//
// Reference implementation: ts-fsrs (pinned in package.json), long-term mode
// (enable_short_term=false, enable_fuzz=false) — day-granularity scheduling,
// matching the OpenKoto card model (spec: docs/specs/vocabulary-srs-spec.md).
//
// The SM-2 seed formula is not part of ts-fsrs; it follows fsrs-rs
// `memory_state_from_sm2` (also used by Anki's FSRS migration) and is
// implemented below with the same pinned weight vector.
//
// Output: ../../docs/specs/fixtures/fsrs_golden_v1.json (+ verbatim iOS copy).
// Regenerate only when the spec changes; commit the result.

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  fsrs,
  generatorParameters,
  createEmptyCard,
  Rating,
  default_w,
  forgetting_curve,
  computeDecayFactor,
} from "ts-fsrs";

const SCHEDULER_VERSION = "fsrs6";
const PARAMS = [...default_w];
const DEFAULT_RETENTION = 0.9;
const BASE_UTC = Date.UTC(2026, 0, 1); // 2026-01-01T00:00:00Z
const DAY_MS = 24 * 60 * 60 * 1000;

const day = (offset) => new Date(BASE_UTC + offset * DAY_MS);

function makeFsrs(retention) {
  return fsrs(
    generatorParameters({
      w: PARAMS,
      request_retention: retention,
      enable_fuzz: false,
      enable_short_term: false,
    })
  );
}

// OpenKoto state overlay: Again => "learning", pass => "review" (spec §2.6).
const stateFor = (grade) => (grade === Rating.Again ? "learning" : "review");

const GRADES = { again: Rating.Again, hard: Rating.Hard, good: Rating.Good, easy: Rating.Easy };

/**
 * reviews: array of { day_offset | "due", grade: name }.
 * "due" resolves to previous review offset + previous scheduled interval
 * (reviewing exactly on the due date).
 */
function runCase(name, reviews, { retention = DEFAULT_RETENTION, retrievabilityChecks = [] } = {}) {
  const engine = makeFsrs(retention);
  let card = createEmptyCard(day(0));
  const resolved = [];
  const expected = [];
  let lastOffset = 0;
  for (const review of reviews) {
    const grade = GRADES[review.grade];
    if (!grade) throw new Error(`unknown grade ${review.grade}`);
    const offset =
      review.day_offset === "due" ? lastOffset + card.scheduled_days : review.day_offset;
    if (offset < lastOffset) throw new Error(`${name}: day_offset going backwards`);
    ({ card } = engine.next(card, day(offset), grade));
    lastOffset = offset;
    resolved.push({ day_offset: offset, grade: review.grade });
    expected.push({
      stability: card.stability,
      difficulty: card.difficulty,
      interval_days: card.scheduled_days,
      state: stateFor(grade),
    });
  }
  const checks = retrievabilityChecks.map(({ after_step, elapsed_days }) => ({
    after_step,
    elapsed_days,
    expected: forgetting_curve(PARAMS, elapsed_days, expected[after_step].stability),
  }));
  return {
    name,
    desired_retention: retention,
    reviews: resolved,
    expected,
    ...(checks.length ? { retrievability_checks: checks } : {}),
  };
}

// SM-2 -> FSRS memory-state seed (fsrs-rs `memory_state_from_sm2`, sm2_retention=0.9).
function seedFromSM2(intervalDays, easeFactor, retention = DEFAULT_RETENTION) {
  const stability = Math.max(intervalDays, 0.1) / (9.0 * (1.0 / retention - 1.0));
  const denominator =
    Math.exp(PARAMS[8]) *
    Math.pow(stability, -PARAMS[9]) *
    (Math.exp((1.0 - retention) * PARAMS[10]) - 1.0);
  const difficulty = 11.0 - (easeFactor - 1.0) / denominator;
  return {
    interval_days: intervalDays,
    ease_factor: easeFactor,
    expected_stability: stability,
    expected_difficulty: Math.min(Math.max(difficulty, 1.0), 10.0),
  };
}

const cases = [
  // Single first review per grade: pins S0/D0 and the cross-grade interval
  // ordering fix-up (again<=hard, hard>=again+1, good>=hard+1, easy>=good+1).
  runCase("first-again", [{ day_offset: 0, grade: "again" }]),
  runCase("first-hard", [{ day_offset: 0, grade: "hard" }]),
  runCase("first-good", [{ day_offset: 0, grade: "good" }], {
    retrievabilityChecks: [
      { after_step: 0, elapsed_days: 1 },
      { after_step: 0, elapsed_days: 5 },
      { after_step: 0, elapsed_days: 30 },
    ],
  }),
  runCase("first-easy", [{ day_offset: 0, grade: "easy" }]),
  runCase(
    "good-chain-on-due",
    [
      { day_offset: 0, grade: "good" },
      { day_offset: "due", grade: "good" },
      { day_offset: "due", grade: "good" },
      { day_offset: "due", grade: "good" },
      { day_offset: "due", grade: "good" },
      { day_offset: "due", grade: "good" },
    ],
    { retrievabilityChecks: [{ after_step: 5, elapsed_days: 30 }] }
  ),
  runCase("lapse-then-relearn", [
    { day_offset: 0, grade: "good" },
    { day_offset: "due", grade: "good" },
    { day_offset: "due", grade: "again" },
    { day_offset: "due", grade: "good" },
    { day_offset: "due", grade: "good" },
  ]),
  runCase("hard-only-chain", [
    { day_offset: 0, grade: "hard" },
    { day_offset: "due", grade: "hard" },
    { day_offset: "due", grade: "hard" },
    { day_offset: "due", grade: "hard" },
  ]),
  runCase("easy-then-good", [
    { day_offset: 0, grade: "easy" },
    { day_offset: "due", grade: "good" },
  ]),
  runCase("same-day-repeat", [
    { day_offset: 0, grade: "good" },
    { day_offset: 0, grade: "again" }, // elapsed 0, long-term lapse: S=min(S, S_forget)
    { day_offset: 0, grade: "good" },  // elapsed 0, pass: stability unchanged, D updates
    { day_offset: 1, grade: "good" },
  ]),
  runCase("late-review", [
    { day_offset: 0, grade: "good" },
    { day_offset: 9, grade: "good" }, // 3x scheduled (3d) late
    { day_offset: "due", grade: "good" },
  ]),
  runCase("early-review", [
    { day_offset: 0, grade: "good" },
    { day_offset: "due", grade: "good" },
    { day_offset: 14, grade: "good" }, // earlier than scheduled
  ]),
  runCase("uncertain-mix", [
    { day_offset: 0, grade: "good" },
    { day_offset: "due", grade: "hard" },
    { day_offset: "due", grade: "good" },
    { day_offset: "due", grade: "again" },
    { day_offset: "due", grade: "hard" },
  ]),
  runCase(
    "retention-080-chain",
    [
      { day_offset: 0, grade: "good" },
      { day_offset: "due", grade: "good" },
      { day_offset: "due", grade: "good" },
    ],
    { retention: 0.8 }
  ),
  runCase("retention-095-first-good", [{ day_offset: 0, grade: "good" }], { retention: 0.95 }),
];

const sm2SeedCases = [
  seedFromSM2(21, 2.6),
  seedFromSM2(1, 2.5),
  seedFromSM2(0, 1.3),   // SM-2 "learning" card: interval 0 -> S floor 0.1
  seedFromSM2(6, 1.3),   // ease at SM-2 floor
  seedFromSM2(100, 3.1),
  seedFromSM2(365, 2.5),
];

const { decay, factor } = computeDecayFactor(PARAMS);
const fixture = {
  schema: "openkoto-fsrs-golden-v1",
  scheduler: SCHEDULER_VERSION,
  generator: "ts-fsrs 5.4.1 (long-term scheduler, fuzz off)",
  params: PARAMS,
  default_desired_retention: DEFAULT_RETENTION,
  maximum_interval: 36500,
  // Derived constants for cross-checking ports (not inputs):
  derived: { decay, factor },
  tolerance: { stability: 1e-6, difficulty: 1e-6, retrievability: 1e-6 },
  cases,
  sm2_seed_cases: sm2SeedCases,
};

const here = dirname(fileURLToPath(import.meta.url));
const canonical = join(here, "..", "..", "docs", "specs", "fixtures", "fsrs_golden_v1.json");
const iosCopy = join(
  here, "..", "..",
  "openkoto-ios", "Packages", "OpenKotoKit", "Tests", "OKSRSTests", "Fixtures",
  "fsrs_golden_v1.json"
);
const json = JSON.stringify(fixture, null, 2) + "\n";
for (const target of [canonical, iosCopy]) {
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, json);
  console.log(`wrote ${target}`);
}
console.log(`${cases.length} cases, ${sm2SeedCases.length} seed cases`);
