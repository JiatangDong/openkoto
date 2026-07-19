//! 复习统计口径测试(规范 §6)。

use openkoto_desktop_lib::commands::build_review_stats;
use openkoto_desktop_lib::types::{FavoriteVocabulary, ReviewEvent};

fn card(id: &str, state: &str, pack: &str, suspended: bool) -> FavoriteVocabulary {
    let json = format!(
        r#"{{
          "id":"{id}","word":"w-{id}","meaning":"m","usage":"u",
          "source_article_id":null,"source_article_title":null,
          "created_at":"2026-02-16T00:00:00Z"
        }}"#
    );
    let mut vocab: FavoriteVocabulary = serde_json::from_str(&json).unwrap();
    vocab.srs_state = state.to_string();
    vocab.pack_ids = vec![pack.to_string()];
    vocab.suspended_at = suspended.then(|| "2026-07-01T00:00:00Z".to_string());
    vocab
}

fn event(card_id: &str, date_local: &str, previous_state: &str) -> ReviewEvent {
    ReviewEvent {
        id: format!("e-{card_id}-{date_local}-{previous_state}"),
        card_id: card_id.to_string(),
        reviewed_at: format!("{date_local}T10:00:00Z"),
        date_local: date_local.to_string(),
        grade: 3,
        elapsed_days: 0,
        previous_state: previous_state.to_string(),
        scheduler_version: "fsrs6".to_string(),
        desired_retention: 0.9,
        result_stability: 2.3065,
        result_difficulty: 2.11810397,
        result_interval_days: 3,
        result_state: "review".to_string(),
    }
}

#[test]
fn today_counts_dedupe_and_prefer_new() {
    let cards = vec![card("a", "review", "p1", false), card("b", "review", "p1", false)];
    let events = vec![
        // 卡 a:当日先 new 后 review → 只计新学
        event("a", "2026-07-17", "new"),
        event("a", "2026-07-17", "learning"),
        // 卡 b:纯复习
        event("b", "2026-07-17", "review"),
        // 其他日期不计
        event("b", "2026-07-16", "review"),
    ];

    let stats = build_review_stats(&cards, &events, "all", "2026-07-17");
    assert_eq!(stats.new_today, 1);
    assert_eq!(stats.review_today, 1);
}

#[test]
fn streak_counts_consecutive_days_across_month_boundary() {
    let cards = vec![card("a", "review", "p1", false)];
    let events = vec![
        event("a", "2026-06-29", "review"),
        event("a", "2026-06-30", "review"),
        event("a", "2026-07-01", "review"),
        // 6-27 有事件但 6-28 断档,不应计入
        event("a", "2026-06-27", "review"),
    ];

    // 今日(7-02)尚无事件:从昨日(7-01)向前数
    let stats = build_review_stats(&cards, &events, "all", "2026-07-02");
    assert_eq!(stats.streak_days, 3);

    // 今日有事件:从今日起算
    let mut with_today = events.clone();
    with_today.push(event("a", "2026-07-02", "review"));
    let stats = build_review_stats(&cards, &with_today, "all", "2026-07-02");
    assert_eq!(stats.streak_days, 4);
}

#[test]
fn distribution_buckets_by_state_and_suspended() {
    let cards = vec![
        card("a", "new", "p1", false),
        card("b", "learning", "p1", false),
        card("c", "review", "p1", false),
        card("d", "review", "p1", true), // 已掌握:只进 suspended 桶
        card("e", "review", "p2", false),
    ];

    let stats = build_review_stats(&cards, &[], "p1", "2026-07-17");
    assert_eq!(stats.total, 4);
    assert_eq!(stats.count_new, 1);
    assert_eq!(stats.count_learning, 1);
    assert_eq!(stats.count_review, 1);
    assert_eq!(stats.count_suspended, 1);

    let all = build_review_stats(&cards, &[], "all", "2026-07-17");
    assert_eq!(all.total, 5);
}

#[test]
fn pack_filter_applies_to_today_counts() {
    let cards = vec![card("a", "review", "p1", false), card("b", "review", "p2", false)];
    let events = vec![
        event("a", "2026-07-17", "review"),
        event("b", "2026-07-17", "review"),
    ];

    let stats = build_review_stats(&cards, &events, "p1", "2026-07-17");
    assert_eq!(stats.review_today, 1);
}
