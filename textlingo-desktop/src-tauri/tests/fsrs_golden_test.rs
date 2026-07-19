//! FSRS 黄金用例测试:跑 docs/specs/fixtures/fsrs_golden_v1.json 全部用例。
//! fixture 由 script/fsrs-golden/ 从 ts-fsrs 5.4.1 生成;规范见 docs/specs/vocabulary-srs-spec.md。

use openkoto_desktop_lib::fsrs;
use serde::Deserialize;

const FIXTURE: &str = include_str!("../../../docs/specs/fixtures/fsrs_golden_v1.json");
const IOS_FIXTURE_COPY: &str = include_str!(
    "../../../openkoto-ios/Packages/OpenKotoKit/Tests/OKSRSTests/Fixtures/fsrs_golden_v1.json"
);

#[derive(Deserialize)]
struct Fixture {
    schema: String,
    scheduler: String,
    params: Vec<f64>,
    cases: Vec<Case>,
    sm2_seed_cases: Vec<SeedCase>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    desired_retention: f64,
    reviews: Vec<Review>,
    expected: Vec<Expected>,
    #[serde(default)]
    retrievability_checks: Vec<RetrievabilityCheck>,
}

#[derive(Deserialize)]
struct Review {
    day_offset: i64,
    grade: String,
}

#[derive(Deserialize)]
struct Expected {
    stability: f64,
    difficulty: f64,
    interval_days: i32,
    state: String,
}

#[derive(Deserialize)]
struct RetrievabilityCheck {
    after_step: usize,
    elapsed_days: f64,
    expected: f64,
}

#[derive(Deserialize)]
struct SeedCase {
    interval_days: i32,
    ease_factor: f64,
    expected_stability: f64,
    expected_difficulty: f64,
}

const TOLERANCE: f64 = 1e-6;

fn grade_value(name: &str) -> u8 {
    match name {
        "again" => 1,
        "hard" => 2,
        "good" => 3,
        "easy" => 4,
        other => panic!("unknown grade {other}"),
    }
}

#[test]
fn fixture_matches_engine_constants() {
    let fixture: Fixture = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(fixture.schema, "openkoto-fsrs-golden-v1");
    assert_eq!(fixture.scheduler, fsrs::SCHEDULER_VERSION);
    assert_eq!(fixture.params.len(), 21);
    for (i, (a, b)) in fixture
        .params
        .iter()
        .zip(fsrs::FSRS6_DEFAULT_PARAMS.iter())
        .enumerate()
    {
        assert!((a - b).abs() < f64::EPSILON, "param w{i} mismatch: {a} vs {b}");
    }
}

#[test]
fn golden_cases_pass() {
    let fixture: Fixture = serde_json::from_str(FIXTURE).unwrap();
    assert!(!fixture.cases.is_empty());

    for case in &fixture.cases {
        let mut stability = 0.0_f64;
        let mut difficulty = 0.0_f64;
        let mut last_offset: Option<i64> = None;
        let mut step_stabilities = Vec::new();

        for (step, (review, expected)) in
            case.reviews.iter().zip(case.expected.iter()).enumerate()
        {
            let elapsed = match last_offset {
                None => 0,
                Some(prev) => review.day_offset - prev,
            };
            let update = fsrs::next_review(
                stability,
                difficulty,
                elapsed,
                grade_value(&review.grade),
                case.desired_retention,
            )
            .unwrap();

            let ctx = format!("case '{}' step {}", case.name, step);
            assert!(
                (update.stability - expected.stability).abs() < TOLERANCE,
                "{ctx}: stability {} != {}",
                update.stability,
                expected.stability
            );
            assert!(
                (update.difficulty - expected.difficulty).abs() < TOLERANCE,
                "{ctx}: difficulty {} != {}",
                update.difficulty,
                expected.difficulty
            );
            assert_eq!(
                update.interval_days, expected.interval_days,
                "{ctx}: interval mismatch"
            );
            assert_eq!(update.srs_state, expected.state, "{ctx}: state mismatch");

            stability = update.stability;
            difficulty = update.difficulty;
            last_offset = Some(review.day_offset);
            step_stabilities.push(stability);
        }

        for check in &case.retrievability_checks {
            let r = fsrs::retrievability(step_stabilities[check.after_step], check.elapsed_days);
            assert!(
                (r - check.expected).abs() < TOLERANCE,
                "case '{}': retrievability after step {} at {}d: {} != {}",
                case.name,
                check.after_step,
                check.elapsed_days,
                r,
                check.expected
            );
        }
    }
}

#[test]
fn sm2_seed_cases_pass() {
    let fixture: Fixture = serde_json::from_str(FIXTURE).unwrap();
    assert!(!fixture.sm2_seed_cases.is_empty());

    for case in &fixture.sm2_seed_cases {
        let (stability, difficulty) = fsrs::seed_from_sm2(case.interval_days, case.ease_factor);
        assert!(
            (stability - case.expected_stability).abs() < TOLERANCE,
            "seed(interval={}, ease={}): stability {} != {}",
            case.interval_days,
            case.ease_factor,
            stability,
            case.expected_stability
        );
        assert!(
            (difficulty - case.expected_difficulty).abs() < TOLERANCE,
            "seed(interval={}, ease={}): difficulty {} != {}",
            case.interval_days,
            case.ease_factor,
            difficulty,
            case.expected_difficulty
        );
    }
}

#[test]
fn grade_mapping_matches_spec() {
    assert_eq!(fsrs::grade_from_str("unknown").unwrap(), 1);
    assert_eq!(fsrs::grade_from_str("uncertain").unwrap(), 2);
    assert_eq!(fsrs::grade_from_str("known").unwrap(), 3);
    assert!(fsrs::grade_from_str("easy").is_err());
}

/// iOS 侧的 fixture 副本必须与权威文件逐字节一致(规范 §7)。
/// 若此测试失败:重新运行 script/fsrs-golden 生成脚本同步两份文件。
#[test]
fn ios_fixture_copy_is_byte_identical() {
    assert_eq!(
        FIXTURE, IOS_FIXTURE_COPY,
        "docs/specs/fixtures/fsrs_golden_v1.json 与 iOS Tests/OKSRSTests/Fixtures 副本不一致"
    );
}
