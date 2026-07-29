import Foundation
import Testing

@testable import OKModels

/// **跨语言契约测试。**
///
/// 下面这段 JSON 不是手写的，是 `textlingo-desktop` 的 Rust 导出器
/// （`transfer_export.rs` 的 `dump_full_fixture`）真实吐出来的字节。
///
/// 两个代码库、两种语言、两套序列化规则，**键名漂移是完全静默的**：
/// iOS 这边只会看到"文件损坏"或者某个字段莫名其妙是空的。
/// 第一次跑这组断言就抓到了一处——嵌套的精讲用的是桌面自己的类型，
/// 序列化成 `cultural_context` 而不是 `culturalContext`，
/// 结果是**每一条精讲都解不开**，而精讲恰恰是最花钱、最该同步的东西。
///
/// 改动任何一边的字段名，都要重新生成这段 fixture。
@Suite struct DesktopInteropTests {
    private static let desktopFixture = """
        {
          "format": "openkoto-transfer",
          "schemaVersion": 1,
          "exportedAt": "2026-07-29T12:00:00Z",
          "sourceApp": "textlingo-desktop",
          "vocabulary": [
            {
              "id": "11111111-1111-4111-8111-111111111111",
              "word": "夢",
              "meaning": "梦",
              "usage": "名词",
              "explanation": "讲解",
              "example": "例句",
              "reading": "ゆめ",
              "sourceArticleId": "33333333-3333-4333-8333-333333333333",
              "sourceArticleTitle": "夢十夜",
              "sourceSegmentId": null,
              "packIds": [
                "22222222-2222-4222-8222-222222222222"
              ],
              "srsState": "review",
              "stability": 3.5,
              "difficulty": 5.1,
              "schedulerVersion": "fsrs6",
              "suspendedAt": null,
              "dueDate": "2026-08-01",
              "lastReviewedAt": "2026-07-29T11:00:00Z",
              "reviewCount": 3,
              "createdAt": "2026-07-01T00:00:00Z",
              "updatedAt": "2026-07-29T10:00:00Z"
            }
          ],
          "packs": [
            {
              "id": "22222222-2222-4222-8222-222222222222",
              "name": "N1",
              "packDescription": "描述",
              "coverURL": null,
              "author": "me",
              "languageFrom": "ja",
              "languageTo": "zh-CN",
              "tags": [
                "jlpt"
              ],
              "version": "1",
              "isSystem": false,
              "createdAt": "2026-07-01T00:00:00Z",
              "updatedAt": "2026-07-02T00:00:00Z"
            }
          ],
          "articles": [
            {
              "id": "33333333-3333-4333-8333-333333333333",
              "title": "夢十夜",
              "content": "こんな夢を見た。",
              "sourceType": "web",
              "sourceURL": "https://example.com",
              "createdAt": "2026-07-01T00:00:00Z"
            }
          ],
          "segments": [
            {
              "id": "44444444-4444-4444-8444-444444444444",
              "articleId": "33333333-3333-4333-8333-333333333333",
              "order": 0,
              "text": "こんな夢を見た。",
              "readingText": "こんなゆめをみた。",
              "translation": "我做了这样一个梦。",
              "explanation": {
                "translation": "我做了这样一个梦。",
                "explanation": "固定搭配",
                "readingText": null,
                "vocabulary": [
                  {
                    "word": "夢",
                    "meaning": "梦",
                    "usage": null,
                    "example": null,
                    "reading": "ゆめ"
                  }
                ],
                "grammarPoints": [
                  {
                    "point": "〜を見る",
                    "explanation": "惯用",
                    "example": "夢を見る"
                  }
                ],
                "culturalContext": "夏目漱石",
                "difficultyLevel": "intermediate",
                "learningTips": "整体记忆"
              },
              "isNewParagraph": true,
              "startTime": 1.5,
              "endTime": 4.0,
              "createdAt": "2026-07-01T00:00:00Z"
            }
          ],
          "reviewEvents": [
            {
              "id": "55555555-5555-4555-8555-555555555555",
              "vocabularyId": "11111111-1111-4111-8111-111111111111",
              "reviewedAt": "2026-07-29T11:00:00Z",
              "dateLocal": "2026-07-29",
              "grade": 3,
              "elapsedDays": 2,
              "previousState": "learning",
              "schedulerVersion": "fsrs6",
              "desiredRetention": 0.9,
              "resultStability": 3.5,
              "resultDifficulty": 5.1,
              "resultIntervalDays": 3,
              "resultState": "review"
            }
          ],
          "tombstones": []
        }
        """

    private func decoded() throws -> TransferBundle {
        try TransferBundle.decode(from: Data(Self.desktopFixture.utf8))
    }

    @Test func envelopeIsUnderstood() throws {
        let bundle = try decoded()
        #expect(bundle.format == TransferBundle.formatID)
        #expect(bundle.schemaVersion == 1)
        #expect(bundle.sourceApp == "textlingo-desktop")
    }

    @Test func vocabularyKeepsItsIdentityAndFSRSState() throws {
        let vocab = try #require(decoded().vocabulary.first)
        #expect(vocab.id == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(vocab.word == "夢")
        // FSRS 状态必须原样过来——这正是它区别于 .okpack.json 分享格式的全部意义
        #expect(vocab.srsState == .review)
        #expect(vocab.stability == 3.5)
        #expect(vocab.difficulty == 5.1)
        #expect(vocab.schedulerVersion == "fsrs6")
        #expect(vocab.dueDate == "2026-08-01")
        #expect(vocab.reviewCount == 3)
        #expect(vocab.lastReviewedAt != nil)
        #expect(vocab.packIds == [UUID(uuidString: "22222222-2222-4222-8222-222222222222")!])
        #expect(vocab.sourceArticleId != nil)
    }

    @Test func packKeepsItsNonObviousKeyNames() throws {
        let pack = try #require(decoded().packs.first)
        // packDescription / coverURL 是两个最容易写错的键名
        #expect(pack.packDescription == "描述")
        #expect(pack.name == "N1")
        #expect(pack.tags == ["jlpt"])
        #expect(!pack.isSystem)
    }

    @Test func articleAndSegmentSurvive() throws {
        let bundle = try decoded()
        let article = try #require(bundle.articles.first)
        #expect(article.title == "夢十夜")
        #expect(article.sourceType == .web)
        #expect(article.sourceURL == "https://example.com")

        let segment = try #require(bundle.segments.first)
        #expect(segment.articleId == article.id)
        #expect(segment.isNewParagraph)
        #expect(segment.startTime == 1.5)
        #expect(segment.readingText == "こんなゆめをみた。")
    }

    /// 精讲的嵌套结构是键名最多、最容易漂移的地方。
    @Test func explanationSurvivesWholeIncludingNestedLists() throws {
        let explanation = try #require(decoded().segments.first?.explanation)
        #expect(explanation.explanation == "固定搭配")
        #expect(explanation.culturalContext == "夏目漱石")
        #expect(explanation.difficultyLevel == "intermediate")
        #expect(explanation.learningTips == "整体记忆")
        #expect(explanation.vocabulary.first?.reading == "ゆめ")
        #expect(explanation.grammarPoints.first?.point == "〜を見る")
        #expect(explanation.grammarPoints.first?.example == "夢を見る")
    }

    /// 复习事件：桌面叫 card_id，iOS 叫 vocabularyId，指同一个东西。
    /// 映射错了的话，复习进度会全部挂到一个不存在的卡片上，静默失效。
    @Test func reviewEventMapsCardIdOntoVocabularyId() throws {
        let event = try #require(decoded().reviewEvents.first)
        #expect(event.vocabularyId == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(event.grade == 3)
        #expect(event.previousState == .learning)
        #expect(event.resultState == .review)
        #expect(event.resultIntervalDays == 3)
    }
}
