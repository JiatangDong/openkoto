use openkoto_desktop_lib::commands::seed_fsrs_if_needed;
use openkoto_desktop_lib::types::FavoriteVocabulary;

#[test]
fn old_favorite_vocabulary_json_deserializes_with_defaults() {
    let old_json = r#"{
      "id":"old-1",
      "word":"apple",
      "meaning":"苹果",
      "usage":"n.",
      "example":null,
      "reading":null,
      "source_article_id":null,
      "source_article_title":null,
      "created_at":"2026-02-16T00:00:00Z"
    }"#;

    let vocab: FavoriteVocabulary = serde_json::from_str(old_json).unwrap();
    assert_eq!(vocab.word, "apple");
    assert!(vocab.pack_ids.is_empty());
    assert_eq!(vocab.srs_state, "new");
    assert!(vocab.ease_factor >= 2.5);
    assert_eq!(vocab.repetitions, 0);
    assert_eq!(vocab.interval_days, 0);
    assert!(!vocab.due_date.is_empty());
    assert_eq!(vocab.review_count, 0);
    // FSRS 字段的 serde 默认值
    assert_eq!(vocab.stability, 0.0);
    assert_eq!(vocab.difficulty, 0.0);
    assert!(vocab.scheduler_version.is_none());
    assert!(vocab.suspended_at.is_none());
}

fn sm2_card(state: &str, review_count: i32, interval_days: i32, ease: f64) -> FavoriteVocabulary {
    let json = r#"{
      "id":"m-1","word":"w","meaning":"m","usage":"u",
      "source_article_id":null,"source_article_title":null,
      "created_at":"2026-02-16T00:00:00Z"
    }"#;
    let mut vocab: FavoriteVocabulary = serde_json::from_str(json).unwrap();
    vocab.srs_state = state.to_string();
    vocab.review_count = review_count;
    vocab.interval_days = interval_days;
    vocab.ease_factor = ease;
    vocab
}

#[test]
fn seed_migrates_reviewed_sm2_card() {
    let mut vocab = sm2_card("review", 5, 21, 2.6);
    let old_due = vocab.due_date.clone();

    assert!(seed_fsrs_if_needed(&mut vocab));
    // 规范 §4:S ≈ interval_days,D 由 ease 推导;due_date 不变
    assert!((vocab.stability - 21.0).abs() < 1e-6);
    assert!(vocab.difficulty > 1.0 && vocab.difficulty < 10.0);
    assert_eq!(vocab.scheduler_version.as_deref(), Some("fsrs6"));
    assert_eq!(vocab.due_date, old_due);
    // 旧字段冻结保留
    assert_eq!(vocab.interval_days, 21);
    assert!((vocab.ease_factor - 2.6).abs() < f64::EPSILON);
}

#[test]
fn seed_skips_new_cards_but_stamps_version() {
    let mut vocab = sm2_card("new", 0, 0, 2.5);
    assert!(seed_fsrs_if_needed(&mut vocab));
    assert_eq!(vocab.stability, 0.0);
    assert_eq!(vocab.difficulty, 0.0);
    assert_eq!(vocab.scheduler_version.as_deref(), Some("fsrs6"));
}

#[test]
fn seed_is_idempotent() {
    let mut vocab = sm2_card("review", 5, 21, 2.6);
    assert!(seed_fsrs_if_needed(&mut vocab));
    let stability = vocab.stability;
    let difficulty = vocab.difficulty;

    // 模拟后续 FSRS 复习改变了状态,再跑 fix-up 不得重种
    vocab.stability = 99.0;
    vocab.difficulty = 3.3;
    assert!(!seed_fsrs_if_needed(&mut vocab));
    assert_eq!(vocab.stability, 99.0);
    assert_eq!(vocab.difficulty, 3.3);

    let _ = (stability, difficulty);
}
