import Foundation
import GRDB
import Testing
import OKModels
@testable import OKPersistence

/// v1 schema 与 ContentRepository 的事务测试（设计文档 §3.2：
/// 文章导入、精讲回填、级联删除、收藏去重）。
@Suite struct ContentRepositoryTests {
    private func makeRepository() throws -> (ContentRepository, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (ContentRepository(database: database), database)
    }

    private func makeArticle(
        title: String = "テスト記事", createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Article {
        Article(title: title, content: "本文", sourceType: .article, createdAt: createdAt)
    }

    private func makeSegments(for article: Article, texts: [String]) -> [ArticleSegment] {
        texts.enumerated().map { index, text in
            ArticleSegment(
                articleId: article.id, order: index, text: text,
                isNewParagraph: index == 0,
                createdAt: article.createdAt
            )
        }
    }

    // MARK: - 建库 / 导入

    @Test func migrationCreatesAllTables() async throws {
        let (_, database) = try makeRepository()
        let tables = try await database.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in [
            "article", "segment", "favorite_vocabulary", "word_pack",
            "word_pack_membership", "review_log",
            "book", "book_chapter", "book_progress", "book_mark",
        ] {
            #expect(tables.contains(expected))
        }
    }

    @Test func insertArticleRoundTripsSegmentsInOrder() async throws {
        let (repository, _) = try makeRepository()
        let article = makeArticle()
        let segments = makeSegments(for: article, texts: ["一句目。", "二句目。", "三句目。"])
        try await repository.insertArticle(article, segments: segments)

        let snapshot = try await repository.loadAll()
        #expect(snapshot.articles.map(\.id) == [article.id])
        #expect(snapshot.articles[0].title == article.title)
        #expect(snapshot.articles[0].sourceType == .article)
        // 句子不再随 loadAll 预载，按需读取；快照只带计数。
        #expect(snapshot.segmentCounts[article.id] == .init(total: 3, explained: 0))
        let loaded = try await repository.loadSegments(articleID: article.id)
        #expect(loaded.map(\.text) == ["一句目。", "二句目。", "三句目。"])
        #expect(loaded.map(\.order) == [0, 1, 2])
        #expect(loaded[0].isNewParagraph)
        #expect(loaded.allSatisfy { $0.explanation == nil })
    }

    @Test func articlesOrderedByCreatedAtDescending() async throws {
        let (repository, _) = try makeRepository()
        let older = makeArticle(title: "older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeArticle(title: "newer", createdAt: Date(timeIntervalSince1970: 2_000))
        try await repository.insertArticle(older, segments: [])
        try await repository.insertArticle(newer, segments: [])
        let snapshot = try await repository.loadAll()
        #expect(snapshot.articles.map(\.title) == ["newer", "older"])
    }

    /// 导入原子性：任一 segment 违反约束（重复 order_index）时整体回滚。
    @Test func insertArticleIsAtomic() async throws {
        let (repository, _) = try makeRepository()
        let article = makeArticle()
        var segments = makeSegments(for: article, texts: ["一句目。", "二句目。"])
        segments[1].order = 0   // 与第一句冲突，违反 UNIQUE(article_id, order_index)

        await #expect(throws: DatabaseError.self) {
            try await repository.insertArticle(article, segments: segments)
        }
        let snapshot = try await repository.loadAll()
        #expect(snapshot.articles.isEmpty)
        #expect(snapshot.segmentCounts.isEmpty)
        #expect(try await repository.loadSegments(articleID: article.id).isEmpty)
    }

    // MARK: - 删除级联

    @Test func deleteArticleCascadesSegmentsAndNullsFavoriteSource() async throws {
        let (repository, database) = try makeRepository()
        let article = makeArticle()
        try await repository.insertArticle(
            article, segments: makeSegments(for: article, texts: ["一句目。"]))
        try await repository.insertFavorite(
            FavoriteVocabulary(
                word: "夢", meaning: "梦",
                sourceArticleId: article.id, sourceArticleTitle: article.title))

        try await repository.deleteArticle(id: article.id)

        let segmentCount = try await database.writer.read { db in
            try SegmentRecord.fetchCount(db)
        }
        #expect(segmentCount == 0)
        let snapshot = try await repository.loadAll()
        #expect(snapshot.articles.isEmpty)
        guard let favorite = snapshot.favorites.first else {
            Issue.record("favorites is empty")
            return
        }
        #expect(favorite.sourceArticleId == nil)          // FK ON DELETE SET NULL
        #expect(favorite.sourceArticleTitle == article.title)  // 标题快照保留
    }

    // MARK: - 精讲回填

    @Test func saveExplanationWritesEnvelopeAndDoesNotOverwrite() async throws {
        let (repository, database) = try makeRepository()
        let article = makeArticle()
        let segments = makeSegments(for: article, texts: ["こんな夢を見た。"])
        try await repository.insertArticle(article, segments: segments)

        let explanation = SegmentExplanation(
            translation: "我做了这样一个梦。",
            explanation: "「夢を見る」是固定搭配。",
            readingText: "こんな ゆめ を みた。")
        let meta = ExplanationMeta(
            targetLanguage: "zh-CN", providerId: "moonshot", modelId: "kimi-k2",
            promptVersion: "explain-v1",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            sourceTextHash: "abc123")

        let written = try await repository.saveExplanation(
            segmentID: segments[0].id, explanation: explanation, meta: meta)
        #expect(written)

        // 镜像列 + 信封内容（snake_case + 溯源元数据）
        let fetched = try #require(
            try await database.writer.read { db -> (String?, String?, String?)? in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT translation, reading_text, explanation_json FROM segment")
                else { return nil }
                return (row["translation"], row["reading_text"], row["explanation_json"])
            })
        #expect(fetched.0 == "我做了这样一个梦。")
        #expect(fetched.1 == "こんな ゆめ を みた。")
        let json = try #require(fetched.2)
        #expect(json.contains("\"prompt_version\":\"explain-v1\""))
        #expect(json.contains("\"source_text_hash\":\"abc123\""))
        let envelope = try WireJSON.decoder.decode(ExplanationEnvelope.self, from: Data(json.utf8))
        #expect(envelope.explanation == explanation)
        #expect(envelope.providerId == "moonshot")
        #expect(envelope.modelId == "kimi-k2")

        // 已精讲的句子不覆盖
        let overwritten = try await repository.saveExplanation(
            segmentID: segments[0].id,
            explanation: SegmentExplanation(translation: "覆盖", explanation: "覆盖"),
            meta: nil)
        #expect(!overwritten)
        let reloaded = try await repository.loadSegments(articleID: article.id)
        let segment = try #require(reloaded.first)
        #expect(segment.explanation == explanation)
        #expect(segment.translation == "我做了这样一个梦。")
    }

    @Test func saveExplanationForMissingSegmentReturnsFalse() async throws {
        let (repository, _) = try makeRepository()
        let written = try await repository.saveExplanation(
            segmentID: UUID(),
            explanation: SegmentExplanation(translation: "t", explanation: "e"),
            meta: nil)
        #expect(!written)
    }

    // MARK: - 收藏去重

    @Test func favoriteDedupByNormalizedWordAndSourceArticle() async throws {
        let (repository, _) = try makeRepository()
        let article = makeArticle()
        try await repository.insertArticle(article, segments: [])
        try await repository.insertFavorite(
            FavoriteVocabulary(word: "Dream", meaning: "梦", sourceArticleId: article.id))

        // 同一来源文章内，规范化词形相同（大小写/首尾空白差异）→ 拒绝
        await #expect(throws: DatabaseError.self) {
            try await repository.insertFavorite(
                FavoriteVocabulary(word: " dream ", meaning: "梦", sourceArticleId: article.id))
        }

        // 不同来源文章 → 允许
        let other = makeArticle(title: "other")
        try await repository.insertArticle(other, segments: [])
        try await repository.insertFavorite(
            FavoriteVocabulary(word: "dream", meaning: "梦", sourceArticleId: other.id))
        let snapshot = try await repository.loadAll()
        #expect(snapshot.favorites.count == 2)
    }

    @Test func favoriteRoundTripsSRSFieldsAndMembership() async throws {
        let (repository, database) = try makeRepository()
        let pack = try await repository.ensureDefaultPack()
        let favorite = FavoriteVocabulary(
            word: "枕元", meaning: "枕边", usage: "枕元に置く",
            example: "枕元に本を置く。", reading: "まくらもと",
            packIds: [pack.id], srsState: .learning,
            stability: 13.82690327, difficulty: 2.11121424,
            schedulerVersion: "fsrs6",
            dueDate: "2026-07-20", reviewCount: 5,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await repository.insertFavorite(favorite)

        let favorites = try await repository.loadAll().favorites
        guard let loaded = favorites.first else {
            Issue.record("favorites is empty")
            return
        }
        #expect(loaded.id == favorite.id)
        #expect(loaded.word == "枕元")
        #expect(loaded.packIds == [pack.id])
        #expect(loaded.srsState == .learning)
        #expect(loaded.stability == 13.82690327)
        #expect(loaded.difficulty == 2.11121424)
        #expect(loaded.schedulerVersion == "fsrs6")
        #expect(loaded.suspendedAt == nil)
        #expect(loaded.dueDate == "2026-07-20")
        #expect(loaded.reviewCount == 5)

        // 删除卡片:membership 级联删除
        try await repository.deleteFavorite(id: favorite.id)
        let after = try await repository.loadAll()
        #expect(after.favorites.isEmpty)
        let membershipCount = try await database.writer.read { db in
            try WordPackMembershipRecord.fetchCount(db)
        }
        #expect(membershipCount == 0)
    }

    @Test func setPackIdsDiffsMembership() async throws {
        let (repository, _) = try makeRepository()
        let defaultPack = try await repository.ensureDefaultPack()
        let favorite = FavoriteVocabulary(word: "夢", meaning: "梦", packIds: [defaultPack.id])
        try await repository.insertFavorite(favorite)

        // 换到另一个词包
        let custom = WordPack(name: "N2 词汇")
        try await repository.insertPack(custom)
        try await repository.setPackIds(vocabularyId: favorite.id, packIds: [custom.id])

        let favorites = try await repository.loadAll().favorites
        guard let loaded = favorites.first else {
            Issue.record("favorites is empty")
            return
        }
        #expect(loaded.packIds == [custom.id])
    }

    // MARK: - 词包管理

    @Test func updatePackRenames() async throws {
        let (repository, _) = try makeRepository()
        var pack = WordPack(name: "旧名")
        try await repository.insertPack(pack)

        pack.name = "新名"
        try await repository.updatePack(pack)

        let packs = try await repository.loadAll().packs
        #expect(packs.map(\.name) == ["新名"])
    }

    @Test func deletePackMovesOrphanedWordsToUngrouped() async throws {
        let (repository, _) = try makeRepository()
        let defaultPack = try await repository.ensureDefaultPack()
        let doomed = WordPack(name: "要删除")
        let keeper = WordPack(name: "保留")
        try await repository.insertPack(doomed)
        try await repository.insertPack(keeper)

        // orphan 只在被删包内;shared 同时在保留包内
        let orphan = FavoriteVocabulary(word: "孤児", meaning: "孤儿", packIds: [doomed.id])
        let shared = FavoriteVocabulary(
            word: "共有", meaning: "共享", packIds: [doomed.id, keeper.id])
        try await repository.insertFavorite(orphan)
        try await repository.insertFavorite(shared)

        try await repository.deletePack(id: doomed.id)

        let snapshot = try await repository.loadAll()
        #expect(!snapshot.packs.contains { $0.id == doomed.id })
        let byId = Dictionary(uniqueKeysWithValues: snapshot.favorites.map { ($0.id, $0) })
        #expect(byId[orphan.id]?.packIds == [defaultPack.id])
        #expect(byId[shared.id]?.packIds == [keeper.id])
    }

    @Test func deleteSystemPackThrows() async throws {
        let (repository, _) = try makeRepository()
        _ = try await repository.ensureDefaultPack()
        await #expect(throws: (any Error).self) {
            try await repository.deletePack(id: WordPack.systemUngroupedID)
        }
        let packs = try await repository.loadAll().packs
        #expect(packs.contains { $0.id == WordPack.systemUngroupedID })
    }

    // MARK: - 已掌握 / 到期队列

    @Test func suspendedCardsAreExcludedFromDueQueue() async throws {
        let (repository, _) = try makeRepository()
        let pack = try await repository.ensureDefaultPack()
        let due = FavoriteVocabulary(
            word: "a", meaning: "m", packIds: [pack.id], dueDate: "2026-07-17")
        let suspended = FavoriteVocabulary(
            word: "b", meaning: "m", packIds: [pack.id], srsState: .review,
            dueDate: "2026-07-17")
        try await repository.insertFavorite(due)
        try await repository.insertFavorite(suspended)
        try await repository.setSuspended(id: suspended.id, suspended: true)

        let queue = try await repository.dueQueue(
            packId: nil, dateLocal: "2026-07-17", newLimit: 20, reviewLimit: 100)
        #expect(queue.map(\.id) == [due.id])

        // 恢复后回队
        try await repository.setSuspended(id: suspended.id, suspended: false)
        let restored = try await repository.dueQueue(
            packId: nil, dateLocal: "2026-07-17", newLimit: 20, reviewLimit: 100)
        #expect(restored.count == 2)
        // new/learning 优先于 review(镜像桌面队列语义)
        #expect(restored.first?.id == due.id)
    }

    @Test func dueQueueFiltersPackAndDateAndAppliesLimits() async throws {
        let (repository, _) = try makeRepository()
        let pack = try await repository.ensureDefaultPack()
        let dueToday = FavoriteVocabulary(
            word: "a", meaning: "m", packIds: [pack.id], dueDate: "2026-07-17")
        let dueTomorrow = FavoriteVocabulary(
            word: "b", meaning: "m", packIds: [pack.id], dueDate: "2026-07-18")
        let noPack = FavoriteVocabulary(word: "c", meaning: "m", dueDate: "2026-07-01")
        try await repository.insertFavorite(dueToday)
        try await repository.insertFavorite(dueTomorrow)
        try await repository.insertFavorite(noPack)

        let queue = try await repository.dueQueue(
            packId: pack.id, dateLocal: "2026-07-17", newLimit: 20, reviewLimit: 100)
        #expect(queue.map(\.id) == [dueToday.id])

        let zeroLimit = try await repository.dueQueue(
            packId: nil, dateLocal: "2026-07-17", newLimit: 0, reviewLimit: 100)
        #expect(zeroLimit.isEmpty)
    }

    // MARK: - 复习事务与统计

    @Test func applyReviewUpdatesCardAndAppendsExactlyOneLogRow() async throws {
        let (repository, database) = try makeRepository()
        let pack = try await repository.ensureDefaultPack()
        var favorite = FavoriteVocabulary(
            word: "夢", meaning: "梦", packIds: [pack.id], dueDate: "2026-07-17")
        try await repository.insertFavorite(favorite)

        // 模拟 FSRS good 首评结果(黄金用例 first-good)
        favorite.srsState = .review
        favorite.stability = 2.3065
        favorite.difficulty = 2.11810397
        favorite.dueDate = "2026-07-20"
        favorite.lastReviewedAt = .now
        favorite.reviewCount = 1
        let event = ReviewEvent(
            vocabularyId: favorite.id, reviewedAt: .now, dateLocal: "2026-07-17",
            grade: 3, elapsedDays: 0, previousState: .new, desiredRetention: 0.9,
            resultStability: 2.3065, resultDifficulty: 2.11810397,
            resultIntervalDays: 3, resultState: .review)
        try await repository.applyReview(favorite, event: event)

        let favorites = try await repository.loadAll().favorites
        guard let loaded = favorites.first else {
            Issue.record("favorites is empty")
            return
        }
        #expect(loaded.srsState == .review)
        #expect(loaded.stability == 2.3065)
        #expect(loaded.dueDate == "2026-07-20")
        #expect(loaded.reviewCount == 1)

        let logCount = try await database.writer.read { db in
            try ReviewLogRecord.fetchCount(db)
        }
        #expect(logCount == 1)

        // 事件在卡片删除后存活(无外键;同步单元,规范 §1.3)
        try await repository.deleteFavorite(id: favorite.id)
        let survivingLogs = try await database.writer.read { db in
            try ReviewLogRecord.fetchCount(db)
        }
        #expect(survivingLogs == 1)
    }

    @Test func reviewStatsMatchSpecFormulas() async throws {
        let cards = [
            FavoriteVocabulary(word: "a", meaning: "m", srsState: .review),
            FavoriteVocabulary(word: "b", meaning: "m", srsState: .review),
            FavoriteVocabulary(word: "c", meaning: "m", srsState: .new),
        ]
        func event(
            _ card: FavoriteVocabulary, _ dateLocal: String, _ previous: SRSState
        ) -> ReviewEvent {
            ReviewEvent(
                vocabularyId: card.id, reviewedAt: .now, dateLocal: dateLocal,
                grade: 3, elapsedDays: 0, previousState: previous, desiredRetention: 0.9,
                resultStability: 1, resultDifficulty: 5, resultIntervalDays: 1,
                resultState: .review)
        }
        let events = [
            // 卡 a:当日先 new 后复习 → 只计新学
            event(cards[0], "2026-07-17", .new),
            event(cards[0], "2026-07-17", .learning),
            // 卡 b:纯复习;昨日与前日也有事件(连续打卡 3 天)
            event(cards[1], "2026-07-17", .review),
            event(cards[1], "2026-07-16", .review),
            event(cards[1], "2026-07-15", .review),
        ]

        let stats = ContentRepository.buildReviewStats(
            favorites: cards, events: events, packId: nil, dateLocal: "2026-07-17")
        #expect(stats.newToday == 1)
        #expect(stats.reviewToday == 1)
        #expect(stats.streakDays == 3)
        #expect(stats.total == 3)
        #expect(stats.countNew == 1)
        #expect(stats.countReview == 2)
    }

    /// 今日进度只数答对了的（规范 §6 的两个派生计数）。
    ///
    /// 这是"点了模糊/不认识也照算进度"那个反馈的判据：答错的卡当天还会回到队列，
    /// 在点「认识」之前 `passed*` 不能动，而"碰过多少张"的 `newToday`/`reviewToday`
    /// 仍按原口径走——两套数并存，谁都不替代谁。
    @Test func passedTodayCountsOnlyCardsAnsweredCorrectly() async throws {
        let learned = FavoriteVocabulary(word: "a", meaning: "m", srsState: .new)
        let stillFailing = FavoriteVocabulary(word: "b", meaning: "m", srsState: .new)
        let reviewed = FavoriteVocabulary(word: "c", meaning: "m", srsState: .review)
        func event(
            _ card: FavoriteVocabulary, grade: Int, previous: SRSState
        ) -> ReviewEvent {
            ReviewEvent(
                vocabularyId: card.id, reviewedAt: .now, dateLocal: "2026-07-17",
                grade: grade, elapsedDays: 0, previousState: previous, desiredRetention: 0.9,
                resultStability: 1, resultDifficulty: 5, resultIntervalDays: 1,
                resultState: grade == 1 ? .learning : .review)
        }
        let events = [
            // 卡 a:又错又错才对 → 碰过 1 张、通过 1 张
            event(learned, grade: 1, previous: .new),
            event(learned, grade: 1, previous: .learning),
            event(learned, grade: 3, previous: .learning),
            // 卡 b:今天一直没对 → 碰过算它，通过不算
            event(stillFailing, grade: 1, previous: .new),
            event(stillFailing, grade: 2, previous: .learning),
            // 卡 c:一次过的复习卡
            event(reviewed, grade: 3, previous: .review),
        ]

        let stats = ContentRepository.buildReviewStats(
            favorites: [learned, stillFailing, reviewed], events: events,
            packId: nil, dateLocal: "2026-07-17")
        #expect(stats.newToday == 2)
        #expect(stats.reviewToday == 1)
        #expect(stats.passedNewToday == 1)
        #expect(stats.passedReviewToday == 1)
    }

    /// 每日上限只截新词：巩固卡的 `last_reviewed_at` 最新、排在组尾，
    /// 一并计入上限就会被当天的新材料整批挤掉，同日巩固步骤（规范 §2.8）形同虚设。
    @Test func dueQueueKeepsLearningCardsBeyondTheNewLimit() async throws {
        let (repository, _) = try makeRepository()
        let fresh = (0..<25).map {
            FavoriteVocabulary(
                word: "new\($0)", meaning: "m", srsState: .new, dueDate: "2026-07-17")
        }
        let relearning = (0..<5).map {
            FavoriteVocabulary(
                word: "again\($0)", meaning: "m", srsState: .learning,
                dueDate: "2026-07-17", lastReviewedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
        for card in fresh + relearning { try await repository.insertFavorite(card) }

        let queue = try await repository.dueQueue(
            packId: nil, dateLocal: "2026-07-17", newLimit: 20, reviewLimit: 100)
        #expect(queue.count == 25)
        #expect(queue.count { $0.srsState == .learning } == 5)
        #expect(queue.count { $0.srsState == .new } == 20)
    }

    /// 提前复习只发未来到期的卡，且与今日队列**没有交集**——
    /// 重叠会让同一张卡在一次会话里出现两遍。
    @Test func aheadQueueTakesTheNextDueCardsWithoutOverlappingToday() async throws {
        let (repository, _) = try makeRepository()
        let today = FavoriteVocabulary(word: "today", meaning: "m", dueDate: "2026-07-17")
        let broken = FavoriteVocabulary(word: "broken", meaning: "m", dueDate: "")
        let suspended = FavoriteVocabulary(
            word: "done", meaning: "m", suspendedAt: .now, dueDate: "2026-07-18")
        let soon = FavoriteVocabulary(word: "soon", meaning: "m", dueDate: "2026-07-18")
        let later = FavoriteVocabulary(word: "later", meaning: "m", dueDate: "2026-07-25")
        for card in [today, broken, suspended, soon, later] {
            try await repository.insertFavorite(card)
        }

        let ahead = try await repository.aheadQueue(
            packId: nil, dateLocal: "2026-07-17", limit: 20)
        #expect(ahead.map(\.word) == ["soon", "later"])

        // 坏日期在 dueQueue 里算"已到期"，所以它必须留在今日那一侧。
        let due = try await repository.dueQueue(
            packId: nil, dateLocal: "2026-07-17", newLimit: 20, reviewLimit: 100)
        #expect(Set(due.map(\.id)).isDisjoint(with: Set(ahead.map(\.id))))
        #expect(due.contains { $0.word == "broken" })

        let capped = try await repository.aheadQueue(
            packId: nil, dateLocal: "2026-07-17", limit: 1)
        #expect(capped.map(\.word) == ["soon"])
    }

    // MARK: - 出处回填

    /// 存量卡（v5 之前收藏的没有 source_segment_id）要靠现查原文才能找回原句。
    @Test func segmentsContainingFindsCandidatesInOrder() async throws {
        let (repository, _) = try makeRepository()
        let article = makeArticle()
        let segments = makeSegments(
            for: article,
            texts: ["犬が走る。", "私は日本語を勉強しています。", "毎日勉強する。"])
        try await repository.insertArticle(article, segments: segments)

        let hits = try await repository.segments(articleID: article.id, containing: "勉強")
        #expect(hits.map(\.order) == [1, 2])
        // ASCII 大小写不敏感：句首大写的英文词也要能命中。
        let other = makeArticle(title: "en")
        try await repository.insertArticle(
            other, segments: makeSegments(for: other, texts: ["Turkey is a country."]))
        #expect(
            try await repository.segments(articleID: other.id, containing: "turkey").count == 1)
        #expect(try await repository.segments(articleID: article.id, containing: "犬").count == 1)
        #expect(try await repository.segments(articleID: article.id, containing: " ").isEmpty)
    }

    @Test func setSourceSegmentOnlyTouchesThatColumn() async throws {
        let (repository, _) = try makeRepository()
        let favorite = FavoriteVocabulary(
            word: "勉強", meaning: "学习", sourceArticleTitle: "ある記事", dueDate: "2026-07-20")
        try await repository.insertFavorite(favorite)
        let segmentID = UUID()

        try await repository.setSourceSegment(vocabularyId: favorite.id, segmentId: segmentID)

        let loaded = try #require(
            try await repository.loadAll().favorites.first { $0.id == favorite.id })
        #expect(loaded.sourceSegmentId == segmentID)
        #expect(loaded.meaning == "学习")
        #expect(loaded.sourceArticleTitle == "ある記事")
        #expect(loaded.dueDate == "2026-07-20")
    }

    // MARK: - 首启种子

    @Test func seedIfEmptyIsIdempotent() async throws {
        let (repository, _) = try makeRepository()
        let article = makeArticle()
        let segments = makeSegments(for: article, texts: ["一句目。"])

        let seeded = try await repository.seedIfEmpty(
            articles: [article], segmentsByArticle: [article.id: segments])
        #expect(seeded)
        let again = try await repository.seedIfEmpty(
            articles: [makeArticle(title: "another")], segmentsByArticle: [:])
        #expect(!again)   // 非空库不再种子

        let snapshot = try await repository.loadAll()
        #expect(snapshot.articles.count == 1)
        #expect(snapshot.segmentCounts[article.id]?.total == 1)
    }
}
