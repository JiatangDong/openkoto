//! 导出「传输包」（`.okdata`），把桌面加工好的素材与词库送进 iOS / iPadOS / macOS。
//!
//! 这是**单向**通道：桌面版是另一个 App，进不了 iOS 那边的 CloudKit 容器，
//! 而 Apple 三平台之间由 CloudKit 自动同步。
//!
//! 与既有的 `.okpack.json`（`openkoto-word-pack-v1`）**并存，互不替代**：
//! 那个是分享格式，不带 id、不带任何 FSRS 状态，按词面去重，适合"把词单发给朋友"；
//! 用它搬自己的数据会把复习进度全部清零。这个格式带稳定 id 与完整 FSRS 状态，
//! 因此可以反复导入而不产生重复。
//!
//! **字段名必须与 iOS 的 Swift `Codable` 默认键一一对应（camelCase）**，
//! 所以全部 struct 都带 `#[serde(rename_all = "camelCase")]`。

use crate::types::{Article, FavoriteVocabulary, ReviewEvent, SegmentExplanation, WordPack};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;
use std::time::SystemTime;

pub const TRANSFER_FORMAT_ID: &str = "openkoto-transfer";
pub const TRANSFER_SCHEMA_VERSION: u32 = 1;

/// 时间戳统一成**不带小数秒**的 UTC 形式（`2026-07-29T12:00:00Z`）。
///
/// `chrono::to_rfc3339()` 默认会带纳秒，而 Swift 的 `.iso8601` 解码策略
/// **不接受小数秒** —— 一个时间戳就能让 iOS 那边整包解码失败。
/// （iOS 侧也已经做了宽容处理，这里仍然输出严格形式，两头都不依赖对方将就。）
fn iso8601(raw: &str) -> Option<String> {
    DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|dt| dt.with_timezone(&Utc).to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn iso8601_from_system_time(time: SystemTime) -> String {
    DateTime::<Utc>::from(time).to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// id 必须是合法 UUID —— iOS 那边所有主键都是 `UUID` 类型，
/// 混进一个非 UUID 会让**整包解码失败**，用户看到的是"文件损坏"。
/// 宁可丢掉这一条，也不能毁掉整个文件。
fn is_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok()
}

/// 桌面的 source_type 比 iOS 多（youtube / local_video / audio / book）。
/// iOS 只有 article | web，且该字段可空 —— 认不出来的一律给 null，
/// 而不是硬塞一个 iOS 解不开的值。
fn map_source_type(raw: Option<&str>) -> Option<String> {
    match raw {
        Some("web") => Some("web".to_string()),
        Some("article") => Some("article".to_string()),
        _ => None,
    }
}

fn map_srs_state(raw: &str) -> String {
    match raw {
        "learning" => "learning".to_string(),
        "review" => "review".to_string(),
        // 认不出来的按"未学"处理：宁可让用户重新学一遍，
        // 也不要塞一个 iOS 解不开的值把整包毁掉。
        _ => "new".to_string(),
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferBundle {
    pub format: String,
    pub schema_version: u32,
    pub exported_at: String,
    pub source_app: String,
    pub vocabulary: Vec<TransferVocabulary>,
    pub packs: Vec<TransferPack>,
    pub articles: Vec<TransferArticle>,
    pub segments: Vec<TransferSegment>,
    pub review_events: Vec<TransferReviewEvent>,
    /// 桌面端没有墓碑表（删除就是删文件），恒为空数组。
    /// 字段必须在：iOS 那边它是非可选的。
    pub tombstones: Vec<serde_json::Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferVocabulary {
    pub id: String,
    pub word: String,
    pub meaning: String,
    pub usage: Option<String>,
    pub explanation: Option<String>,
    pub example: Option<String>,
    pub reading: Option<String>,
    pub source_article_id: Option<String>,
    pub source_article_title: Option<String>,
    pub source_segment_id: Option<String>,
    pub pack_ids: Vec<String>,
    pub srs_state: String,
    pub stability: f64,
    pub difficulty: f64,
    pub scheduler_version: Option<String>,
    pub suspended_at: Option<String>,
    pub due_date: String,
    pub last_reviewed_at: Option<String>,
    pub review_count: i32,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferPack {
    pub id: String,
    pub name: String,
    /// iOS 侧属性名是 `packDescription`（`description` 与既有 API 冲突）。
    pub pack_description: Option<String>,
    #[serde(rename = "coverURL")]
    pub cover_url: Option<String>,
    pub author: Option<String>,
    pub language_from: Option<String>,
    pub language_to: Option<String>,
    pub tags: Vec<String>,
    pub version: Option<String>,
    pub is_system: bool,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferArticle {
    pub id: String,
    pub title: String,
    pub content: String,
    pub source_type: Option<String>,
    #[serde(rename = "sourceURL")]
    pub source_url: Option<String>,
    pub created_at: String,
}


/// 精讲。**不能直接复用 `types::SegmentExplanation`** ——
/// 它没有 `rename_all = "camelCase"`，序列化出来是 `cultural_context` /
/// `grammar_points` 这样的 snake_case，而 iOS 要的是 `culturalContext` /
/// `grammarPoints`。直接复用会让**每一条精讲都解不开**，
/// 而精讲恰恰是最花钱、最该同步的东西。
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferExplanation {
    pub translation: String,
    pub explanation: String,
    pub reading_text: Option<String>,
    pub vocabulary: Vec<TransferVocabularyItem>,
    pub grammar_points: Vec<TransferGrammarPoint>,
    pub cultural_context: Option<String>,
    pub difficulty_level: Option<String>,
    pub learning_tips: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferVocabularyItem {
    pub word: String,
    pub meaning: String,
    /// iOS 侧是可空的；桌面是 String，空串按 null 处理。
    pub usage: Option<String>,
    pub example: Option<String>,
    pub reading: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferGrammarPoint {
    pub point: String,
    pub explanation: String,
    pub example: Option<String>,
}

impl From<&SegmentExplanation> for TransferExplanation {
    fn from(source: &SegmentExplanation) -> Self {
        TransferExplanation {
            translation: source.translation.clone(),
            explanation: source.explanation.clone(),
            reading_text: source.reading_text.clone(),
            vocabulary: source
                .vocabulary
                .iter()
                .map(|item| TransferVocabularyItem {
                    word: item.word.clone(),
                    meaning: item.meaning.clone(),
                    usage: if item.usage.trim().is_empty() {
                        None
                    } else {
                        Some(item.usage.clone())
                    },
                    example: item.example.clone(),
                    reading: item.reading.clone(),
                })
                .collect(),
            grammar_points: source
                .grammar_points
                .iter()
                .map(|point| TransferGrammarPoint {
                    point: point.point.clone(),
                    explanation: point.explanation.clone(),
                    example: point.example.clone(),
                })
                .collect(),
            cultural_context: source.cultural_context.clone(),
            difficulty_level: source.difficulty_level.clone(),
            learning_tips: source.learning_tips.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferSegment {
    pub id: String,
    pub article_id: String,
    pub order: i32,
    pub text: String,
    pub reading_text: Option<String>,
    pub translation: Option<String>,
    pub explanation: Option<TransferExplanation>,
    pub is_new_paragraph: bool,
    pub start_time: Option<f64>,
    pub end_time: Option<f64>,
    pub created_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferReviewEvent {
    pub id: String,
    /// 桌面叫 `card_id`，iOS 叫 `vocabularyId`，指的是同一个东西。
    pub vocabulary_id: String,
    pub reviewed_at: String,
    pub date_local: String,
    pub grade: u8,
    pub elapsed_days: i64,
    pub previous_state: String,
    pub scheduler_version: String,
    pub desired_retention: f64,
    pub result_stability: f64,
    pub result_difficulty: f64,
    pub result_interval_days: i32,
    pub result_state: String,
}

/// 转换过程中被丢掉的记录数，报给用户看，别静默吞掉。
#[derive(Debug, Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferSkipped {
    pub vocabulary: usize,
    pub packs: usize,
    pub articles: usize,
    pub segments: usize,
    pub review_events: usize,
}

impl TransferSkipped {
    pub fn total(&self) -> usize {
        self.vocabulary + self.packs + self.articles + self.segments + self.review_events
    }
}

pub fn build_vocabulary(
    favorite: &FavoriteVocabulary,
    modified_at: Option<SystemTime>,
) -> Option<TransferVocabulary> {
    if !is_uuid(&favorite.id) {
        return None;
    }
    let created_at = iso8601(&favorite.created_at)?;
    // 没有 updated_at 就用文件 mtime；再退一步用 created_at。
    let updated_at = modified_at
        .map(iso8601_from_system_time)
        .unwrap_or_else(|| created_at.clone());

    Some(TransferVocabulary {
        id: favorite.id.clone(),
        word: favorite.word.clone(),
        meaning: favorite.meaning.clone(),
        usage: if favorite.usage.trim().is_empty() {
            None
        } else {
            Some(favorite.usage.clone())
        },
        explanation: favorite.explanation.clone(),
        example: favorite.example.clone(),
        reading: favorite.reading.clone(),
        source_article_id: favorite.source_article_id.clone().filter(|id| is_uuid(id)),
        source_article_title: favorite.source_article_title.clone(),
        source_segment_id: None,
        pack_ids: favorite
            .pack_ids
            .iter()
            .filter(|id| is_uuid(id))
            .cloned()
            .collect(),
        srs_state: map_srs_state(&favorite.srs_state),
        stability: favorite.stability,
        difficulty: favorite.difficulty,
        scheduler_version: favorite.scheduler_version.clone(),
        suspended_at: favorite.suspended_at.as_deref().and_then(iso8601),
        due_date: favorite.due_date.clone(),
        last_reviewed_at: favorite.last_reviewed_at.as_deref().and_then(iso8601),
        review_count: favorite.review_count,
        created_at,
        updated_at,
    })
}

pub fn build_pack(pack: &WordPack) -> Option<TransferPack> {
    // 系统包("未分组")在 iOS 端由 ensureDefaultPack 各自保证存在，
    // 而且桌面这边它的 id 是字符串常量 "system-ungrouped"，根本不是 UUID。
    if pack.is_system || !is_uuid(&pack.id) {
        return None;
    }
    Some(TransferPack {
        id: pack.id.clone(),
        name: pack.name.clone(),
        pack_description: pack.description.clone(),
        cover_url: pack.cover_url.clone(),
        author: pack.author.clone(),
        language_from: pack.language_from.clone(),
        language_to: pack.language_to.clone(),
        tags: pack.tags.clone(),
        version: pack.version.clone(),
        is_system: false,
        created_at: iso8601(&pack.created_at)?,
        updated_at: iso8601(&pack.updated_at)?,
    })
}

pub fn build_article(article: &Article) -> Option<(TransferArticle, Vec<TransferSegment>)> {
    if !is_uuid(&article.id) {
        return None;
    }
    let created_at = iso8601(&article.created_at)?;
    let segments = article
        .segments
        .iter()
        .filter(|segment| is_uuid(&segment.id) && segment.article_id == article.id)
        .filter_map(|segment| {
            Some(TransferSegment {
                id: segment.id.clone(),
                article_id: segment.article_id.clone(),
                order: segment.order,
                text: segment.text.clone(),
                reading_text: segment.reading_text.clone(),
                translation: segment.translation.clone(),
                explanation: segment.explanation.as_ref().map(TransferExplanation::from),
                is_new_paragraph: segment.is_new_paragraph,
                start_time: segment.start_time,
                end_time: segment.end_time,
                created_at: iso8601(&segment.created_at).unwrap_or_else(|| created_at.clone()),
            })
        })
        .collect();

    Some((
        TransferArticle {
            id: article.id.clone(),
            title: article.title.clone(),
            content: article.content.clone(),
            source_type: map_source_type(article.source_type.as_deref()),
            source_url: article.source_url.clone(),
            created_at,
        },
        segments,
    ))
}

pub fn build_review_event(event: &ReviewEvent) -> Option<TransferReviewEvent> {
    if !is_uuid(&event.id) || !is_uuid(&event.card_id) {
        return None;
    }
    Some(TransferReviewEvent {
        id: event.id.clone(),
        vocabulary_id: event.card_id.clone(),
        reviewed_at: iso8601(&event.reviewed_at)?,
        date_local: event.date_local.clone(),
        grade: event.grade,
        elapsed_days: event.elapsed_days,
        previous_state: map_srs_state(&event.previous_state),
        scheduler_version: event.scheduler_version.clone(),
        desired_retention: event.desired_retention,
        result_stability: event.result_stability,
        result_difficulty: event.result_difficulty,
        result_interval_days: event.result_interval_days,
        result_state: map_srs_state(&event.result_state),
    })
}

pub fn export_file_name(exported_at: &DateTime<Utc>) -> String {
    format!("OpenKoto-{}.okdata", exported_at.format("%Y-%m-%d"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_lose_their_fractional_seconds() {
        // Swift 的 .iso8601 不接受小数秒；带上就会让 iOS 整包解码失败。
        assert_eq!(
            iso8601("2026-07-29T12:00:00.123456789+00:00").unwrap(),
            "2026-07-29T12:00:00Z"
        );
        // 带时区偏移的一律归一到 UTC
        assert_eq!(
            iso8601("2026-07-29T20:00:00+08:00").unwrap(),
            "2026-07-29T12:00:00Z"
        );
        assert!(iso8601("not a timestamp").is_none());
    }

    #[test]
    fn non_uuid_ids_are_rejected_rather_than_breaking_the_whole_file() {
        assert!(is_uuid("550e8400-e29b-41d4-a716-446655440000"));
        // 桌面的系统词包 id 就是这个字符串常量，塞给 iOS 会让整包解码失败
        assert!(!is_uuid("system-ungrouped"));
        assert!(!is_uuid(""));
    }

    #[test]
    fn unknown_source_types_become_null_instead_of_an_undecodable_value() {
        assert_eq!(map_source_type(Some("web")).as_deref(), Some("web"));
        assert_eq!(map_source_type(Some("article")).as_deref(), Some("article"));
        // iOS 的 SourceType 只有 article | web，其余必须给 null
        assert_eq!(map_source_type(Some("youtube")), None);
        assert_eq!(map_source_type(Some("local_video")), None);
        assert_eq!(map_source_type(None), None);
    }

    #[test]
    fn unknown_srs_states_fall_back_to_new() {
        assert_eq!(map_srs_state("review"), "review");
        assert_eq!(map_srs_state("learning"), "learning");
        assert_eq!(map_srs_state("relearning"), "new");
        assert_eq!(map_srs_state(""), "new");
    }

    #[test]
    fn field_names_match_the_swift_codable_keys() {
        let bundle = TransferBundle {
            format: TRANSFER_FORMAT_ID.to_string(),
            schema_version: TRANSFER_SCHEMA_VERSION,
            exported_at: "2026-07-29T12:00:00Z".to_string(),
            source_app: "textlingo-desktop".to_string(),
            vocabulary: vec![],
            packs: vec![],
            articles: vec![],
            segments: vec![],
            review_events: vec![],
            tombstones: vec![],
        };
        let json = serde_json::to_string(&bundle).unwrap();
        // 这几个键名一旦漂移，iOS 那边就是"文件损坏"，而且没有任何提示
        assert!(json.contains("\"schemaVersion\""));
        assert!(json.contains("\"exportedAt\""));
        assert!(json.contains("\"sourceApp\""));
        assert!(json.contains("\"reviewEvents\""));
        assert!(json.contains("\"tombstones\""));
    }

    #[test]
    fn export_file_name_carries_the_date() {
        let at = DateTime::parse_from_rfc3339("2026-07-29T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(export_file_name(&at), "OpenKoto-2026-07-29.okdata");
    }

    /// **iOS 契约测试的 fixture 生成器。**
    ///
    /// 打印一份含每种记录的完整传输包，供
    /// `openkoto-ios/.../Tests/OKModelsTests/DesktopInteropTests.swift` 使用。
    /// 那边的断言吃的就是这里吐出的真实字节 —— 两个代码库之间的键名漂移
    /// 是完全静默的，只有让一边真的去解另一边的输出才能发现。
    ///
    /// 改了任何字段名之后重新生成：
    /// ```
    /// cargo test --lib transfer_export::tests::dump_full_fixture -- --nocapture
    /// ```
    #[test]
    fn dump_full_fixture() {
        let bundle = TransferBundle {
            format: TRANSFER_FORMAT_ID.to_string(),
            schema_version: TRANSFER_SCHEMA_VERSION,
            exported_at: "2026-07-29T12:00:00Z".to_string(),
            source_app: "textlingo-desktop".to_string(),
            vocabulary: vec![TransferVocabulary {
                id: "11111111-1111-4111-8111-111111111111".into(),
                word: "夢".into(), meaning: "梦".into(),
                usage: Some("名词".into()), explanation: Some("讲解".into()),
                example: Some("例句".into()), reading: Some("ゆめ".into()),
                source_article_id: Some("33333333-3333-4333-8333-333333333333".into()),
                source_article_title: Some("夢十夜".into()), source_segment_id: None,
                pack_ids: vec!["22222222-2222-4222-8222-222222222222".into()],
                srs_state: "review".into(), stability: 3.5, difficulty: 5.1,
                scheduler_version: Some("fsrs6".into()), suspended_at: None,
                due_date: "2026-08-01".into(),
                last_reviewed_at: Some("2026-07-29T11:00:00Z".into()),
                review_count: 3,
                created_at: "2026-07-01T00:00:00Z".into(),
                updated_at: "2026-07-29T10:00:00Z".into(),
            }],
            packs: vec![TransferPack {
                id: "22222222-2222-4222-8222-222222222222".into(),
                name: "N1".into(), pack_description: Some("描述".into()),
                cover_url: None, author: Some("me".into()),
                language_from: Some("ja".into()), language_to: Some("zh-CN".into()),
                tags: vec!["jlpt".into()], version: Some("1".into()), is_system: false,
                created_at: "2026-07-01T00:00:00Z".into(),
                updated_at: "2026-07-02T00:00:00Z".into(),
            }],
            articles: vec![TransferArticle {
                id: "33333333-3333-4333-8333-333333333333".into(),
                title: "夢十夜".into(), content: "こんな夢を見た。".into(),
                source_type: Some("web".into()),
                source_url: Some("https://example.com".into()),
                created_at: "2026-07-01T00:00:00Z".into(),
            }],
            segments: vec![TransferSegment {
                id: "44444444-4444-4444-8444-444444444444".into(),
                article_id: "33333333-3333-4333-8333-333333333333".into(),
                order: 0, text: "こんな夢を見た。".into(),
                reading_text: Some("こんなゆめをみた。".into()),
                translation: Some("我做了这样一个梦。".into()),
                explanation: Some(TransferExplanation {
                    translation: "我做了这样一个梦。".into(),
                    explanation: "固定搭配".into(),
                    reading_text: None,
                    vocabulary: vec![TransferVocabularyItem {
                        word: "夢".into(), meaning: "梦".into(),
                        usage: None, example: None, reading: Some("ゆめ".into()),
                    }],
                    grammar_points: vec![TransferGrammarPoint {
                        point: "〜を見る".into(), explanation: "惯用".into(),
                        example: Some("夢を見る".into()),
                    }],
                    cultural_context: Some("夏目漱石".into()),
                    difficulty_level: Some("intermediate".into()),
                    learning_tips: Some("整体记忆".into()),
                }),
                is_new_paragraph: true, start_time: Some(1.5), end_time: Some(4.0),
                created_at: "2026-07-01T00:00:00Z".into(),
            }],
            review_events: vec![TransferReviewEvent {
                id: "55555555-5555-4555-8555-555555555555".into(),
                vocabulary_id: "11111111-1111-4111-8111-111111111111".into(),
                reviewed_at: "2026-07-29T11:00:00Z".into(),
                date_local: "2026-07-29".into(), grade: 3, elapsed_days: 2,
                previous_state: "learning".into(), scheduler_version: "fsrs6".into(),
                desired_retention: 0.9, result_stability: 3.5, result_difficulty: 5.1,
                result_interval_days: 3, result_state: "review".into(),
            }],
            tombstones: vec![],
        };
        println!("===FIXTURE_START===");
        println!("{}", serde_json::to_string_pretty(&bundle).unwrap());
        println!("===FIXTURE_END===");
    }
}
