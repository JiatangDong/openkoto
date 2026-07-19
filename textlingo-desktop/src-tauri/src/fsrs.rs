//! FSRS-6 调度引擎(长期模式,天粒度)。
//!
//! 跨端契约:docs/specs/vocabulary-srs-spec.md §2。
//! 与 openkoto-ios 的 OKSRS/FSRS.swift 必须通过同一份黄金用例
//! docs/specs/fixtures/fsrs_golden_v1.json(见 tests/fsrs_golden_test.rs)。
//! 求值顺序与 round8 出现位置对齐参考实现 ts-fsrs 5.4.1,不得调整。

pub const FSRS6_DEFAULT_PARAMS: [f64; 21] = [
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835,
    0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
];

pub const SCHEDULER_VERSION: &str = "fsrs6";
pub const DEFAULT_DESIRED_RETENTION: f64 = 0.9;
const S_MIN: f64 = 0.001;
const MAX_INTERVAL: i32 = 36500;
const SM2_RETENTION: f64 = 0.9;

#[derive(Debug, Clone, PartialEq)]
pub struct FsrsUpdate {
    pub stability: f64,
    pub difficulty: f64,
    pub interval_days: i32,
    pub srs_state: String,
}

fn round8(x: f64) -> f64 {
    (x * 1e8).round() / 1e8
}

fn clamp(x: f64, lo: f64, hi: f64) -> f64 {
    x.max(lo).min(hi)
}

fn decay() -> f64 {
    -FSRS6_DEFAULT_PARAMS[20]
}

fn factor() -> f64 {
    round8(0.9_f64.powf(1.0 / decay()) - 1.0)
}

/// 保持率 R(t, S)。t 为距上次复习的天数(允许小数);t=0 → 1。
pub fn retrievability(stability: f64, elapsed_days: f64) -> f64 {
    if stability <= 0.0 {
        return 0.0;
    }
    round8((1.0 + factor() * elapsed_days / stability).powf(decay()))
}

fn interval_modifier(desired_retention: f64) -> Result<f64, String> {
    if desired_retention <= 0.0 || desired_retention > 1.0 {
        return Err(format!(
            "Invalid desired_retention {desired_retention}, expected (0, 1]"
        ));
    }
    Ok(round8(
        (desired_retention.powf(1.0 / decay()) - 1.0) / factor(),
    ))
}

fn next_interval(stability: f64, modifier: f64) -> i32 {
    let raw = (stability * modifier).round().max(1.0);
    (raw as i32).min(MAX_INTERVAL)
}

fn init_stability(grade: u8) -> f64 {
    FSRS6_DEFAULT_PARAMS[(grade - 1) as usize].max(0.1)
}

/// 注意:仅在 new 卡初始化路径 clamp 到 [1,10];mean_reversion 里用的
/// init_difficulty(4) 保持原值(可为负),与参考实现一致。
fn init_difficulty(grade: u8) -> f64 {
    let w = &FSRS6_DEFAULT_PARAMS;
    round8(w[4] - (((grade - 1) as f64) * w[5]).exp() + 1.0)
}

fn linear_damping(delta_d: f64, old_d: f64) -> f64 {
    round8(delta_d * (10.0 - old_d) / 9.0)
}

fn mean_reversion(init: f64, current: f64) -> f64 {
    let w = &FSRS6_DEFAULT_PARAMS;
    round8(w[7] * init + (1.0 - w[7]) * current)
}

fn next_difficulty(difficulty: f64, grade: u8) -> f64 {
    let w = &FSRS6_DEFAULT_PARAMS;
    let delta_d = -w[6] * ((grade as f64) - 3.0);
    let next_d = difficulty + linear_damping(delta_d, difficulty);
    clamp(mean_reversion(init_difficulty(4), next_d), 1.0, 10.0)
}

fn next_recall_stability(difficulty: f64, stability: f64, r: f64, grade: u8) -> f64 {
    let w = &FSRS6_DEFAULT_PARAMS;
    let hard_penalty = if grade == 2 { w[15] } else { 1.0 };
    let easy_bonus = if grade == 4 { w[16] } else { 1.0 };
    round8(clamp(
        stability
            * (1.0
                + w[8].exp()
                    * (11.0 - difficulty)
                    * stability.powf(-w[9])
                    * (((1.0 - r) * w[10]).exp() - 1.0)
                    * hard_penalty
                    * easy_bonus),
        S_MIN,
        MAX_INTERVAL as f64,
    ))
}

fn next_forget_stability(difficulty: f64, stability: f64, r: f64) -> f64 {
    let w = &FSRS6_DEFAULT_PARAMS;
    round8(clamp(
        w[11]
            * difficulty.powf(-w[12])
            * ((stability + 1.0).powf(w[13]) - 1.0)
            * (((1.0 - r) * w[14]).exp()),
        S_MIN,
        MAX_INTERVAL as f64,
    ))
}

/// 单档位记忆状态更新(规范 §2.4)。
fn next_memory_state(stability: f64, difficulty: f64, elapsed_days: i64, grade: u8) -> (f64, f64) {
    if stability == 0.0 && difficulty == 0.0 {
        return (
            init_stability(grade),
            clamp(init_difficulty(grade), 1.0, 10.0),
        );
    }
    let r = retrievability(stability, elapsed_days as f64);
    let new_s = if grade == 1 {
        // 长期模式失败:S ← min(S, S_forget)
        clamp(
            round8(stability),
            S_MIN,
            next_forget_stability(difficulty, stability, r),
        )
    } else {
        next_recall_stability(difficulty, stability, r, grade)
    };
    (new_s, next_difficulty(difficulty, grade))
}

/// 一次复习(规范 §2.5):同时计算四档并做跨档位间隔排序修正后取所选档。
pub fn next_review(
    stability: f64,
    difficulty: f64,
    elapsed_days: i64,
    grade: u8,
    desired_retention: f64,
) -> Result<FsrsUpdate, String> {
    if !(1..=4).contains(&grade) {
        return Err(format!("Invalid grade {grade}, expected 1..=4"));
    }
    if elapsed_days < 0 {
        return Err(format!("Invalid elapsed_days {elapsed_days}"));
    }
    let modifier = interval_modifier(desired_retention)?;

    let mut states = [(0.0_f64, 0.0_f64); 4];
    let mut intervals = [0_i32; 4];
    for g in 1..=4u8 {
        let state = next_memory_state(stability, difficulty, elapsed_days, g);
        intervals[(g - 1) as usize] = next_interval(state.0, modifier);
        states[(g - 1) as usize] = state;
    }
    // 排序修正(顺序执行,与参考实现一致)
    intervals[0] = intervals[0].min(intervals[1]);
    intervals[1] = intervals[1].max(intervals[0] + 1);
    intervals[2] = intervals[2].max(intervals[1] + 1);
    intervals[3] = intervals[3].max(intervals[2] + 1);

    let idx = (grade - 1) as usize;
    Ok(FsrsUpdate {
        stability: states[idx].0,
        difficulty: states[idx].1,
        interval_days: intervals[idx],
        srs_state: if grade == 1 { "learning" } else { "review" }.to_string(),
    })
}

/// SM-2 → FSRS 一次性种子(规范 §4,来源 fsrs-rs memory_state_from_sm2)。
pub fn seed_from_sm2(interval_days: i32, ease_factor: f64) -> (f64, f64) {
    let w = &FSRS6_DEFAULT_PARAMS;
    let stability = (interval_days as f64).max(0.1) / (9.0 * (1.0 / SM2_RETENTION - 1.0));
    let denominator =
        w[8].exp() * stability.powf(-w[9]) * (((1.0 - SM2_RETENTION) * w[10]).exp() - 1.0);
    let difficulty = clamp(11.0 - (ease_factor - 1.0) / denominator, 1.0, 10.0);
    (stability, difficulty)
}

/// UI 三档评分 → 引擎档位:不认识→1(Again),模糊→2(Hard),认识→3(Good)。
pub fn grade_from_str(grade: &str) -> Result<u8, String> {
    match grade {
        "unknown" => Ok(1),
        "uncertain" => Ok(2),
        "known" => Ok(3),
        _ => Err("Invalid grade, expected unknown|uncertain|known".to_string()),
    }
}
