import Foundation
import Observation
import os
import OKModels
import OKSegmentation
import OKAIClient
import OKBooks
import OKPersistence
import OKSRS

/// 内容数据仓库：内存态驱动 UI，写操作先更新内存（乐观），再经串行队列落 GRDB。
///
/// - 精讲请求走真实 AI（`explanationProvider`，由 App 壳注入 `AppConfigStore.explain`）；
///   未注入 provider 时（如 SwiftUI 预览）显式报 `.notConfigured`，不伪造内容。
/// - 首次启动种子写入内置示例文章（UserDefaults 防重，用户删除后不复活）。
/// - 落库失败仅日志 + `lastPersistenceFailure` 标记（本地 SQLite 写失败极罕见），
///   内存态保持可用；错误横幅 UI 排后续。
@MainActor
@Observable
public final class ContentStore {
    public private(set) var articles: [Article] = []
    /// 只保留**已打开**的文章/章节的句子（见 `openArticle`）。
    public private(set) var segmentsByArticle: [UUID: [ArticleSegment]] = [:]
    /// 全部文章/章节的句子计数：进度徽章不需要正文，启动时只查计数。
    public private(set) var segmentCounts: [UUID: ContentRepository.SegmentCounts] = [:]
    public private(set) var books: [Book] = []
    /// 章节摘要（不含正文），整本一次性加载，供目录与阅读器翻章使用。
    public private(set) var chapterSummariesByBook: [UUID: [BookChapterSummary]] = [:]
    public private(set) var progressByBook: [UUID: BookProgress] = [:]
    /// 书签与划线，按书聚拢。数量小，随书籍元数据一起全量加载。
    public private(set) var marksByBook: [UUID: [BookMark]] = [:]
    public private(set) var favorites: [FavoriteVocabulary] = []
    public private(set) var packs: [WordPack] = []
    /// 生词本当前选中的词包(nil = 全部);复习队列与统计随之过滤。
    public var activePackId: UUID?
    public private(set) var reviewStats: ReviewStats?
    /// 统计分析(图表)聚合结果；切到统计 Tab 时按需刷新。
    public private(set) var statistics: StudyStatistics?
    public private(set) var generatingSegmentIDs: Set<UUID> = []

    /// 统计窗口：近 30 天活动 + 未来 14 天到期预测。
    public static let statsRangeDays = 30
    public static let statsForecastDays = 14

    /// 每日上限与期望保持率(规范 §3)。默认 20/100/0.9，设置页可改（存 UserDefaults）。
    public static var dailyNewLimit: Int {
        let value = UserDefaults.standard.integer(forKey: "srs.dailyNewLimit")
        return value == 0 ? 20 : value
    }
    public static var dailyReviewLimit: Int {
        let value = UserDefaults.standard.integer(forKey: "srs.dailyReviewLimit")
        return value == 0 ? 100 : value
    }
    public static var desiredRetention: Double {
        let value = UserDefaults.standard.double(forKey: "srs.desiredRetention")
        return value == 0 ? FSRS.defaultDesiredRetention : value
    }
    /// 逐句精讲失败原因（供 ExplanationSheet 展示 + 重试）。
    public private(set) var generationErrors: [UUID: AIClientError] = [:]
    public private(set) var lastPersistenceFailure: String?

    /// 真实精讲入口（App 壳注入）。签名：原文 → 结构化精讲 + 溯源元数据。
    @ObservationIgnored public var explanationProvider:
        ((String) async throws -> GeneratedExplanation)?

    @ObservationIgnored private let repository: ContentRepository
    @ObservationIgnored private let bookRepository: BookRepository?
    @ObservationIgnored private let bookStorage: BookStorage?
    @ObservationIgnored private let defaults: UserDefaults
    /// 已载入句子的文章 LRU 顺序（尾部最新）。
    @ObservationIgnored private var loadedOrder: [UUID] = []
    /// 已打开章节的 Article 缓存（章节不在 `articles` 里）。
    @ObservationIgnored private var chapterArticleCache: [UUID: Article] = [:]
    /// 落库操作串行链：保证与内存更新同序提交。
    @ObservationIgnored private var persistChain: Task<Void, Never>?

    private static let didSeedSamplesKey = "content.didSeedSamples.v1"
    private static let logger = Logger(subsystem: "app.openkoto", category: "ContentStore")

    public init(
        repository: ContentRepository,
        bookRepository: BookRepository? = nil,
        bookStorage: BookStorage? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.bookRepository = bookRepository
        self.bookStorage = bookStorage
        self.defaults = defaults
    }

    /// 主 App 使用的落盘库（Application Support/OpenKoto/openkoto.sqlite）。
    /// 建库失败回退内存库：App 本次会话仍可用，但数据不落盘（已记录日志）。
    public static func live() -> ContentStore {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("OpenKoto", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let database = try AppDatabase.onDisk(
                at: directory.appendingPathComponent("openkoto.sqlite"))
            let storage = try? BookStorage.applicationSupport()
            try? storage?.prepare()
            return ContentStore(
                repository: ContentRepository(database: database),
                bookRepository: BookRepository(database: database),
                bookStorage: storage)
        } catch {
            logger.error("open on-disk database failed, falling back to in-memory: \(error)")
            let database = try! AppDatabase.inMemory()
            let store = ContentStore(repository: ContentRepository(database: database))
            store.lastPersistenceFailure = "database open failed: \(error)"
            return store
        }
    }

    // MARK: - 启动加载

    /// 首启种子示例内容后全量加载到内存。App 壳在注入 provider 后调用一次。
    public func load() async {
        do {
            if !defaults.bool(forKey: Self.didSeedSamplesKey) {
                let sample = SampleData.make()
                try await repository.seedIfEmpty(
                    articles: sample.articles, segmentsByArticle: sample.segments)
                defaults.set(true, forKey: Self.didSeedSamplesKey)
            }
            try await repository.ensureDefaultPack()
            let snapshot = try await repository.loadAll()
            articles = snapshot.articles
            segmentCounts = snapshot.segmentCounts
            favorites = snapshot.favorites
            packs = snapshot.packs
            await loadBooks()
            await refreshStats()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-seedStatsDemo") {
                await seedStatsDemo()
            }
            #endif
        } catch {
            Self.logger.error("load failed: \(error)")
            lastPersistenceFailure = "load failed: \(error)"
        }
    }

    #if DEBUG
    /// 截图/QA 用(-seedStatsDemo)：合成生词 + 复习日志 + 阅读会话填满统计图表。
    /// 首次(favorites 为空)注入；日期键与聚合器一致(UTC 公历，从今日本地日期起递减)。
    private func seedStatsDemo() async {
        guard favorites.isEmpty else { return }
        let now = Date.now
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = Self.localDateString(now).split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts.first
        comps.month = parts.count > 1 ? parts[1] : nil
        comps.day = parts.count > 2 ? parts[2] : nil
        let todayUTC = utc.date(from: comps) ?? now
        func dayKey(_ offset: Int) -> String {
            let date = utc.date(byAdding: .day, value: offset, to: todayUTC) ?? todayUTC
            let c = utc.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        var demoFavorites: [FavoriteVocabulary] = []
        for i in 0..<30 {
            let state: SRSState
            var suspended: Date? = nil
            var stability = 0.0
            var due = ""
            var last: Date? = nil
            switch i % 5 {
            case 0:
                state = .new
            case 1:
                state = .learning
                stability = 1 + Double(i % 3)
                last = utc.date(byAdding: .day, value: -(i % 3), to: now)
                due = dayKey(i % 3)
            case 2:
                state = .review
                stability = Double(8 + i)          // 高稳定 + 近期复习 → 保持良好
                last = utc.date(byAdding: .day, value: -(i % 4), to: now)
                due = dayKey(i % 14)
            case 3:
                state = .review
                stability = Double(2 + i % 3)       // 低稳定 + 久未复习 → 衰减/遗忘
                last = utc.date(byAdding: .day, value: -(6 + i % 18), to: now)
                due = dayKey(-(i % 3))              // 逾期 → 并入预测首日
            default:
                state = .review
                suspended = now                     // 已掌握(暂停)
                stability = Double(30 + i)
                last = utc.date(byAdding: .day, value: -(i % 15), to: now)
            }
            demoFavorites.append(FavoriteVocabulary(
                word: "デモ\(i)", meaning: "demo meaning \(i)", reading: "でも\(i)",
                srsState: state, stability: stability, difficulty: Double(3 + i % 6),
                suspendedAt: suspended, dueDate: due, lastReviewedAt: last,
                reviewCount: i % 7))
        }

        var demoEvents: [ReviewEvent] = []
        for d in 0..<30 {
            let count = (d % 4) + 1
            for j in 0..<count {
                let card = demoFavorites[(d * 3 + j) % demoFavorites.count]
                let isNew = j == 0 && d % 3 == 0
                let grade = [3, 3, 4, 2, 3, 1][(d + j) % 6]
                demoEvents.append(ReviewEvent(
                    vocabularyId: card.id,
                    reviewedAt: utc.date(byAdding: .day, value: -d, to: now) ?? now,
                    dateLocal: dayKey(-d),
                    grade: grade,
                    elapsedDays: d % 5,
                    previousState: isNew ? .new : .review,
                    desiredRetention: 0.9,
                    resultStability: 2 + Double(d),
                    resultDifficulty: 5,
                    resultIntervalDays: 1 + d % 10,
                    resultState: isNew ? .learning : .review))
            }
        }

        var demoSessions: [ReadingSession] = []
        for d in 0..<30 where d % 6 != 5 {          // 留几天空档
            let minutes = 3 + (d * 7 % 25)
            demoSessions.append(ReadingSession(
                articleId: articles.first?.id,
                dateLocal: dayKey(-d),
                startedAt: utc.date(byAdding: .day, value: -d, to: now) ?? now,
                seconds: minutes * 60))
        }

        do {
            try await repository.seedDemo(
                favorites: demoFavorites, events: demoEvents, sessions: demoSessions)
            let snapshot = try await repository.loadAll()
            articles = snapshot.articles
            segmentCounts = snapshot.segmentCounts
            favorites = snapshot.favorites
            packs = snapshot.packs
            await refreshStats()
            await refreshStatistics()   // 种子提交后重算，覆盖视图早期在空库上的计算
        } catch {
            Self.logger.error("seedStatsDemo failed: \(error)")
        }
    }
    #endif

    /// 书籍元数据 + 章节摘要 + 阅读位置。都不含正文，整体很小。
    /// 顺带清理孤儿目录（导入中途崩溃/取消留下的残留）。
    private func loadBooks() async {
        guard let bookRepository else { return }
        do {
            let loaded = try await bookRepository.loadBooks()
            books = loaded
            progressByBook = try await bookRepository.loadProgress()
            var summaries: [UUID: [BookChapterSummary]] = [:]
            var marks: [UUID: [BookMark]] = [:]
            for book in loaded {
                summaries[book.id] = try await bookRepository.chapterSummaries(bookID: book.id)
                marks[book.id] = try await bookRepository.marks(bookID: book.id)
            }
            chapterSummariesByBook = summaries
            marksByBook = marks

            if let bookStorage {
                let knownIDs = Set(loaded.map(\.id))
                Task.detached(priority: .background) {
                    try? bookStorage.sweepOrphans(knownIDs: knownIDs)
                }
            }
        } catch {
            Self.logger.error("loadBooks failed: \(error)")
            lastPersistenceFailure = "loadBooks failed: \(error)"
        }
    }

    // MARK: - 查询

    public func segments(for articleID: UUID) -> [ArticleSegment] {
        segmentsByArticle[articleID] ?? []
    }

    /// 精讲进度（已精讲句数 / 总句数）。
    /// 已打开的文章以内存态为准（精讲刚写回时立刻反映），未打开的用启动时查到的计数。
    public func progress(for articleID: UUID) -> (explained: Int, total: Int) {
        if let segments = segmentsByArticle[articleID] {
            return (segments.count(where: { $0.explanation != nil }), segments.count)
        }
        let counts = segmentCounts[articleID] ?? .init()
        return (counts.explained, counts.total)
    }

    // MARK: - 按需加载

    /// 常驻内存的文章上限。读书时前后翻章很频繁，留几章避免来回读库。
    static let loadedArticleLimit = 3

    /// 打开一篇文章/一章：载入它的句子。
    ///
    /// 书籍章节在导入时**不切分**（一本 50 万字小说会产生上万句），
    /// 首次打开时才切——切分逻辑由 `lazySegmenter` 注入，`OKFeatures` 不直接依赖导入管线。
    public func openArticle(_ articleID: UUID) async {
        touch(articleID)
        guard segmentsByArticle[articleID] == nil else {
            // 刚导入的文章句子已在内存里，但还没注音（导入路径不做注音）。
            await annotateReadings(articleID: articleID)
            return
        }
        do {
            var segments = try await repository.loadSegments(articleID: articleID)
            // 章节 Article 不在 articles 列表里，打开时缓存一份给精讲弹窗用。
            if !articles.contains(where: { $0.id == articleID }),
                chapterArticleCache[articleID] == nil,
                let article = try await repository.article(id: articleID)
            {
                chapterArticleCache[articleID] = article
            }
            if segments.isEmpty, let article = try await repository.article(id: articleID) {
                if let lazySegmenter {
                    segments = await lazySegmenter(article)
                } else {
                    segments = await bookChapterSegments(for: article)
                }
                if !segments.isEmpty {
                    let snapshot = segments
                    persist("replaceSegments") { [repository] in
                        try await repository.replaceSegments(
                            articleID: articleID, segments: snapshot)
                    }
                }
            }
            segmentsByArticle[articleID] = segments
            segmentCounts[articleID] = .init(
                total: segments.count,
                explained: segments.count(where: { $0.explanation != nil }))
            evictIfNeeded()
            // 正文已可显示，注音在后台补上——不要让它挡住首屏。
            await annotateReadings(articleID: articleID)
        } catch {
            Self.logger.error("openArticle failed: \(error)")
            lastPersistenceFailure = "openArticle failed: \(error)"
        }
    }

    /// 章节首开时的延迟切分。默认走 `bookChapterSegments`（读原始文件取注音），
    /// 测试可注入替身。返回空数组表示无需切分。
    @ObservationIgnored public var lazySegmenter: ((Article) async -> [ArticleSegment])?

    /// 书籍章节的延迟切分：优先读原始文件拿注音，文件不在则退回 `article.content`。
    private func bookChapterSegments(for article: Article) async -> [ArticleSegment] {
        guard let bookRepository, let bookStorage,
            let chapter = try? await bookRepository.chapter(articleID: article.id),
            let book = books.first(where: { $0.id == chapter.bookId })
        else { return [] }

        let source = chapter.sourceHref.map {
            bookStorage.directory(for: book.id).appendingPathComponent($0)
        }
        let articleID = article.id
        let content = article.content
        let format = book.format
        // 一章上百句，切分放到后台，别卡住翻页动画。
        return await Task.detached(priority: .userInitiated) {
            ChapterSegmenter().segments(
                articleID: articleID, plainTextFallback: content,
                sourceFile: source, format: format)
        }.value
    }

    private func touch(_ articleID: UUID) {
        loadedOrder.removeAll { $0 == articleID }
        loadedOrder.append(articleID)
    }

    /// 超出上限的最久未用文章从内存卸载；计数保留，进度徽章不受影响。
    private func evictIfNeeded() {
        while loadedOrder.count > Self.loadedArticleLimit {
            let victim = loadedOrder.removeFirst()
            segmentsByArticle[victim] = nil
            readingRunsByArticle[victim] = nil
        }
    }

    // MARK: - 词级读音（振假名 / 拼音）

    /// 已打开文章的词级读音：articleID → segmentID → runs。只存**有注音**的句子。
    ///
    /// 不落库：一章两百句离线注音只要几十毫秒，而 runs 的格式后续还会随
    /// 「原书 ruby / AI 精讲」两个来源演进，过早固化 schema 是负债。
    public private(set) var readingRunsByArticle: [UUID: [UUID: [ReadingRun]]] = [:]

    @ObservationIgnored private let readingAnnotator = LocalReadingAnnotator()

    public func readingRuns(for articleID: UUID) -> [UUID: [ReadingRun]] {
        readingRunsByArticle[articleID] ?? [:]
    }

    /// 给一篇/一章的所有句子标注读音。
    ///
    /// 三层叠加，后盖的赢（可靠性从低到高）：
    /// 1. **离线注音器**铺满全文——覆盖 100%，但约 10% 会错；
    /// 2. **AI 精讲的生词表**盖上去——精讲过的句子里那几个重点词就准了，
    ///    也是英语/法语这类系统无能为力的语种唯一的读音来源（AI 给 IPA）；
    /// 3. **原书自带的 `<ruby>` / 青空 `《》`** 盖在最上——作者标的，权威。
    ///
    /// 语种**按整章取样判一次**，不逐句判——日语文章里「日本語」这种纯汉字句
    /// 单独看会被当成中文，注出一串拼音。语种判不出来时第 1 层跳过，但 2、3 层照常，
    /// 所以英文文章精讲之后依然有音标可看。
    public func annotateReadings(articleID: UUID) async {
        guard readingRunsByArticle[articleID] == nil,
            let segments = segmentsByArticle[articleID], !segments.isEmpty
        else { return }

        let sample = segments.prefix(20).map(\.text).joined(separator: "\n")
        let hint = bookLanguage(forChapter: articleID) ?? ArticleLanguage.detect(sample)
        let language = ReadingLanguageDetector.detect(text: sample, hint: hint)
        let bookRuby = await bookRubyRuns(articleID: articleID, segments: segments)

        let input = segments.map {
            (id: $0.id, text: $0.text, vocabulary: Self.vocabularyEntries(of: $0))
        }
        let annotator = readingAnnotator
        readingRunsByArticle[articleID] = await Task.detached(priority: .utility) {
            input.reduce(into: [UUID: [ReadingRun]]()) { result, segment in
                let runs = Self.composeReadings(
                    text: segment.text, language: language, vocabulary: segment.vocabulary,
                    bookRuby: bookRuby[segment.id], annotator: annotator)
                if runs.hasReadings { result[segment.id] = runs }
            }
        }.value
    }

    /// 精讲刚落库时重算这一句——新拿到的生词读音立刻生效，不用退出重进。
    public func refreshReadings(articleID: UUID, segmentID: UUID) {
        guard readingRunsByArticle[articleID] != nil,
            let segment = segmentsByArticle[articleID]?.first(where: { $0.id == segmentID })
        else { return }

        let sample = (segmentsByArticle[articleID] ?? []).prefix(20).map(\.text)
            .joined(separator: "\n")
        let hint = bookLanguage(forChapter: articleID) ?? ArticleLanguage.detect(sample)
        let runs = Self.composeReadings(
            text: segment.text,
            language: ReadingLanguageDetector.detect(text: sample, hint: hint),
            vocabulary: Self.vocabularyEntries(of: segment),
            // 原书 ruby 已经在打开章节时盖过；这里只补 AI 生词，不再重解析文件。
            bookRuby: nil,
            annotator: readingAnnotator)
        if runs.hasReadings {
            readingRunsByArticle[articleID]?[segmentID] = runs
        }
    }

    /// 纯函数，`nonisolated` 以便整章注音在后台线程跑。
    nonisolated private static func composeReadings(
        text: String, language: ReadingLanguage, vocabulary: [VocabularyReadingMatcher.Entry],
        bookRuby: [ReadingRun]?, annotator: LocalReadingAnnotator
    ) -> [ReadingRun] {
        var runs =
            language == .unsupported
            ? [ReadingRun(text: text)] : annotator.annotate(text, language: language)
        if !vocabulary.isEmpty {
            runs = ReadingOverlay.apply(
                VocabularyReadingMatcher.spans(for: vocabulary, in: text), to: runs)
        }
        if let bookRuby {
            runs = ReadingOverlay.apply(ReadingOverlay.spans(of: bookRuby), to: runs)
        }
        return runs
    }

    private static func vocabularyEntries(
        of segment: ArticleSegment
    ) -> [VocabularyReadingMatcher.Entry] {
        (segment.explanation?.vocabulary ?? []).compactMap { item in
            guard let reading = item.reading, !reading.isEmpty else { return nil }
            return VocabularyReadingMatcher.Entry(word: item.word, reading: reading)
        }
    }

    /// 原书自带的振假名：重新解析章节原始文件，按句还原 run 边界。
    /// 不是书、或原始文件已丢失（换机恢复后 Books/ 未回来）时返回空。
    private func bookRubyRuns(
        articleID: UUID, segments: [ArticleSegment]
    ) async -> [UUID: [ReadingRun]] {
        guard let bookRepository, let bookStorage,
            let chapter = try? await bookRepository.chapter(articleID: articleID),
            let book = books.first(where: { $0.id == chapter.bookId }),
            let href = chapter.sourceHref
        else { return [:] }

        let source = bookStorage.directory(for: book.id).appendingPathComponent(href)
        let format = book.format
        let sentences = segments.map(\.text)
        let ids = segments.map(\.id)

        return await Task.detached(priority: .utility) {
            let ruby = ChapterSegmenter.rubyText(
                sourceFile: source, format: format, fallback: "")
            guard ruby.hasReadings else { return [:] }
            return zip(ids, ruby.runs(forSentencesIn: sentences))
                .reduce(into: [UUID: [ReadingRun]]()) { result, pair in
                    if let runs = pair.1 { result[pair.0] = runs }
                }
        }.value
    }

    /// 书籍的 language 比正文检测可靠（EPUB 从 OPF 读、青空 TXT 固定 ja）。
    private func bookLanguage(forChapter articleID: UUID) -> String? {
        for book in books
        where chapterSummariesByBook[book.id]?.contains(where: { $0.articleId == articleID }) == true
        {
            return book.language
        }
        return nil
    }

    /// 离开阅读器时不立即卸载——回到书库再进来是最常见的操作，留给 LRU 决定。
    public func closeArticle(_ articleID: UUID) {
        evictIfNeeded()
    }

    public func isFavorite(word: String) -> Bool {
        favorites.contains { $0.word == word }
    }

    // MARK: - 导入 / 删除

    public func importArticle(title: String, content: String) {
        let article = Article(title: title, content: content)
        let drafts = SentenceSegmenter().segment(content)
        let segments = drafts.enumerated().map { index, draft in
            ArticleSegment(
                articleId: article.id,
                order: index,
                text: draft.text,
                isNewParagraph: draft.isNewParagraph
            )
        }
        articles.insert(article, at: 0)
        segmentsByArticle[article.id] = segments
        segmentCounts[article.id] = .init(total: segments.count, explained: 0)
        touch(article.id)
        evictIfNeeded()
        persist("importArticle") { [repository] in
            try await repository.insertArticle(article, segments: segments)
        }
    }

    // MARK: - 书籍

    /// 导入一本书（TXT / EPUB）。
    ///
    /// 章节写成 article 行但**不写 segment**——切分推迟到首次打开该章。
    /// - Returns: 导入的书；内容太短（不够成书）时返回 nil，调用方按普通文章导入。
    @discardableResult
    public func importBook(from url: URL, title: String? = nil) async throws -> Book? {
        guard let bookRepository, let bookStorage else { return nil }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let importer = BookImporter(storage: bookStorage)
        let imported = try await Task.detached(priority: .userInitiated) {
            try importer.importBook(from: url, title: title)
        }.value
        guard let imported else { return nil }

        let book = imported.book
        var pairs: [(article: Article, chapter: BookChapter)] = []
        for (index, chapter) in imported.chapters.enumerated() {
            let article = Article(
                title: chapter.title, content: chapter.plainText,
                sourceType: .article, createdAt: book.createdAt)
            pairs.append(
                (
                    article,
                    BookChapter(
                        articleId: article.id, bookId: book.id, index: index,
                        sourceHref: chapter.sourceHref, isSegmented: false,
                        charCount: chapter.charCount)
                ))
        }

        books.insert(book, at: 0)
        chapterSummariesByBook[book.id] = pairs.map {
            BookChapterSummary(
                articleId: $0.article.id, index: $0.chapter.index, title: $0.article.title,
                charCount: $0.chapter.charCount, isSegmented: false,
                sourceHref: $0.chapter.sourceHref)
        }
        for pair in pairs { segmentCounts[pair.article.id] = .init() }

        let snapshot = pairs
        persist("importBook") { [bookRepository] in
            try await bookRepository.insertBook(book, chapters: snapshot)
        }
        return book
    }

    public func chapterSummaries(of bookID: UUID) -> [BookChapterSummary] {
        chapterSummariesByBook[bookID] ?? []
    }

    /// 章节对应的 Article。章节行不在 `articles`（那是书库顶层列表），
    /// 打开时缓存一份供精讲弹窗使用。
    public func chapterArticle(id articleID: UUID) -> Article? {
        articles.first { $0.id == articleID } ?? chapterArticleCache[articleID]
    }

    public func progress(ofBook bookID: UUID) -> BookProgress? {
        progressByBook[bookID]
    }

    // MARK: - 书签 / 划线

    public func marks(ofBook bookID: UUID) -> [BookMark] {
        marksByBook[bookID] ?? []
    }

    public func marks(ofBook bookID: UUID, chapterIndex: Int) -> [BookMark] {
        marks(ofBook: bookID).filter { $0.chapterIndex == chapterIndex }
    }

    /// 新增/更新一条标记。两种模式的锚点尽量都补齐，切模式后仍能定位。
    public func saveMark(_ mark: BookMark) {
        guard let bookRepository else { return }
        var list = marksByBook[mark.bookId] ?? []
        if let index = list.firstIndex(where: { $0.id == mark.id }) {
            list[index] = mark
        } else {
            list.append(mark)
        }
        marksByBook[mark.bookId] = list.sorted {
            ($0.chapterIndex, $0.createdAt) < ($1.chapterIndex, $1.createdAt)
        }
        persist("saveMark") { [bookRepository] in
            try await bookRepository.saveMark(mark)
        }
    }

    public func deleteMark(_ mark: BookMark) {
        guard let bookRepository else { return }
        marksByBook[mark.bookId]?.removeAll { $0.id == mark.id }
        persist("deleteMark") { [bookRepository] in
            try await bookRepository.deleteMark(id: mark.id)
        }
    }

    /// 书籍解压目录（原版模式加载章节文件、解析相对资源都靠它）。
    public func bookDirectory(for bookID: UUID) -> URL? {
        bookStorage?.directory(for: bookID)
    }

    /// 章节原始文件的相对路径。
    public func chapterSourceHref(articleID: UUID) -> String? {
        for summaries in chapterSummariesByBook.values {
            if let match = summaries.first(where: { $0.articleId == articleID }) {
                return match.sourceHref
            }
        }
        return nil
    }

    /// 原版模式里点了站内链接：把文件 URL 换算回章节序号。
    public func chapterIndex(of bookID: UUID, fileURL: URL) -> Int? {
        guard let root = bookStorage?.directory(for: bookID) else { return nil }
        let path = fileURL.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let href = String(path.dropFirst(prefix.count))
        return chapterSummariesByBook[bookID]?
            .first { $0.sourceHref == href }?
            .index
    }

    /// 阅读位置：内存立即更新，落库走串行链（调用方已按 ≥3s 节流）。
    public func saveBookProgress(_ progress: BookProgress) {
        guard let bookRepository else { return }
        progressByBook[progress.bookId] = progress
        persist("saveBookProgress") { [bookRepository] in
            try await bookRepository.saveProgress(progress)
        }
    }

    /// 书名 · 章节名——生词卡片的来源快照，书删掉之后这行字还得有意义。
    public func sourceTitle(forChapter articleID: UUID) -> String? {
        for book in books {
            guard let summary = chapterSummariesByBook[book.id]?
                .first(where: { $0.articleId == articleID })
            else { continue }
            return "\(book.title) · \(summary.title)"
        }
        return nil
    }

    public func deleteBook(_ bookID: UUID) {
        guard let bookRepository else { return }
        let summaries = chapterSummariesByBook[bookID] ?? []

        books.removeAll { $0.id == bookID }
        chapterSummariesByBook[bookID] = nil
        progressByBook[bookID] = nil
        marksByBook[bookID] = nil
        for summary in summaries {
            segmentsByArticle[summary.articleId] = nil
            segmentCounts[summary.articleId] = nil
            loadedOrder.removeAll { $0 == summary.articleId }
            // 镜像 FK ON DELETE SET NULL：收藏保留标题快照、来源置空
            for index in favorites.indices
            where favorites[index].sourceArticleId == summary.articleId {
                favorites[index].sourceArticleId = nil
            }
        }

        let storage = bookStorage
        persist("deleteBook") { [bookRepository] in
            try await bookRepository.deleteBook(id: bookID)
            try storage?.remove(id: bookID)
        }
    }

    /// 排空 Share Extension 收件箱（App Group inbox），把分享的内容导入书库。
    /// URL 信封若未带正文则用 TextImport 抓取；失败的条目静默跳过。
    public func importFromInbox() async {
        guard let inbox = ShareInbox() else { return }
        for envelope in inbox.drain() {
            switch envelope.payload {
            case .plainText(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                importArticle(title: Self.draftTitle(from: trimmed), content: trimmed)
            case .url(let urlString, let title, let text):
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    importArticle(
                        title: title ?? Self.draftTitle(from: text), content: text)
                } else if let fetched = try? await TextImport.fetchArticle(from: urlString) {
                    importArticle(title: title ?? fetched.title, content: fetched.content)
                }
            case .file(let relativePath, let filename, _):
                // 扩展只能写 App Group 容器，文件在那里；导入完删掉，别把容器撑大。
                let url = inbox.fileURL(relativePath: relativePath)
                defer { try? FileManager.default.removeItem(at: url) }
                let title = (filename as NSString).deletingPathExtension
                await importFile(at: url, title: title.isEmpty ? filename : title)
            }
        }
    }

    /// 文件导入的统一入口：先试书籍，不够成书再按普通文章导入。
    /// `.onOpenURL`（"用 OpenKoto 打开"）与分享收件箱都走这里。
    public func importFile(at url: URL, title: String? = nil) async {
        do {
            if try await importBook(from: url, title: title) != nil { return }
        } catch {
            Self.logger.error("importFile failed: \(error)")
            lastPersistenceFailure = "importFile: \(error)"
            return
        }
        guard let parsed = try? TextImport.readTextFile(at: url),
            !parsed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        importArticle(title: title ?? parsed.title, content: parsed.content)
    }

    private static func draftTitle(from content: String) -> String {
        String(content.prefix(while: { !$0.isNewline }).prefix(40))
    }

    public func deleteArticle(_ articleID: UUID) {
        articles.removeAll { $0.id == articleID }
        segmentsByArticle[articleID] = nil
        segmentCounts[articleID] = nil
        loadedOrder.removeAll { $0 == articleID }
        // 镜像 FK ON DELETE SET NULL：收藏保留标题快照、来源置空
        for index in favorites.indices where favorites[index].sourceArticleId == articleID {
            favorites[index].sourceArticleId = nil
        }
        persist("deleteArticle") { [repository] in
            try await repository.deleteArticle(id: articleID)
        }
    }

    // MARK: - AI 精讲

    /// 真实翻译入口（App 壳注入）。签名：原文 → 纯译文。未注入时报 `.notConfigured`。
    @ObservationIgnored public var translationProvider: ((String) async throws -> String)?

    /// - Returns: 是否成功产出精讲（供批量任务统计）。
    @discardableResult
    public func generateExplanation(articleID: UUID, segmentID: UUID) async -> Bool {
        guard let segments0 = segmentsByArticle[articleID],
              let index0 = segments0.firstIndex(where: { $0.id == segmentID }),
              segments0[index0].explanation == nil,
              !generatingSegmentIDs.contains(segmentID)
        else { return false }

        guard let provider = explanationProvider else {
            generationErrors[segmentID] = .notConfigured
            return false
        }

        let text = segments0[index0].text
        generatingSegmentIDs.insert(segmentID)
        generationErrors[segmentID] = nil
        defer { generatingSegmentIDs.remove(segmentID) }

        let generated: GeneratedExplanation
        do {
            generated = try await provider(text)
        } catch let error as AIClientError {
            generationErrors[segmentID] = error
            return false
        } catch is CancellationError {
            return false
        } catch {
            generationErrors[segmentID] = .malformedResponse(requestID: UUID())
            return false
        }

        // 写回前重新校验：防止用户切换文章/重切分后旧请求覆盖新数据（设计文档 §4.6）。
        guard var segments = segmentsByArticle[articleID],
              let index = segments.firstIndex(where: { $0.id == segmentID }),
              segments[index].explanation == nil
        else { return false }
        segments[index].explanation = generated.explanation
        segments[index].translation = generated.explanation.translation
        if let reading = generated.explanation.readingText {
            segments[index].readingText = reading
        }
        segmentsByArticle[articleID] = segments
        // 计数同步递增：文章被 LRU 卸载后进度徽章仍要正确。
        segmentCounts[articleID, default: .init(total: segments.count)].explained += 1
        // 精讲带回了生词读音，比离线注音准——立刻盖上去。
        refreshReadings(articleID: articleID, segmentID: segmentID)

        let explanation = generated.explanation
        let meta = generated.meta
        persist("saveExplanation") { [repository] in
            try await repository.saveExplanation(
                segmentID: segmentID, explanation: explanation, meta: meta)
        }
        return true
    }

    /// 只翻译一句（快翻）：产生 `.translated` chip 态，不做精讲。
    /// 已精讲或已翻译的句子跳过。- Returns: 是否成功产出译文。
    @discardableResult
    public func generateTranslation(articleID: UUID, segmentID: UUID) async -> Bool {
        guard let segments0 = segmentsByArticle[articleID],
              let index0 = segments0.firstIndex(where: { $0.id == segmentID }),
              segments0[index0].explanation == nil,
              segments0[index0].translation == nil,
              !generatingSegmentIDs.contains(segmentID)
        else { return false }

        guard let provider = translationProvider else {
            generationErrors[segmentID] = .notConfigured
            return false
        }

        let text = segments0[index0].text
        generatingSegmentIDs.insert(segmentID)
        generationErrors[segmentID] = nil
        defer { generatingSegmentIDs.remove(segmentID) }

        let translation: String
        do {
            translation = try await provider(text)
        } catch let error as AIClientError {
            generationErrors[segmentID] = error
            return false
        } catch is CancellationError {
            return false
        } catch {
            generationErrors[segmentID] = .malformedResponse(requestID: UUID())
            return false
        }
        guard !translation.isEmpty else { return false }

        guard var segments = segmentsByArticle[articleID],
              let index = segments.firstIndex(where: { $0.id == segmentID }),
              segments[index].explanation == nil, segments[index].translation == nil
        else { return false }
        segments[index].translation = translation
        segmentsByArticle[articleID] = segments

        persist("saveTranslation") { [repository] in
            try await repository.saveTranslation(segmentID: segmentID, translation: translation)
        }
        return true
    }

    // MARK: - 全文批量任务（精讲 / 翻译）

    /// 批量任务进度（供阅读器进度条 + 取消）。
    public struct BatchState: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case explain, translate }
        public var kind: Kind
        public var completed: Int
        public var total: Int
        public var failed: Int
    }

    public private(set) var batchByArticle: [UUID: BatchState] = [:]
    @ObservationIgnored private var batchTasks: [UUID: Task<Void, Never>] = [:]

    /// 并发度（设置页可改，默认 3，钳制 1...6）。
    private var batchConcurrency: Int {
        let value = defaults.integer(forKey: "ai.batchConcurrency")
        return value == 0 ? 3 : min(max(value, 1), 6)
    }

    public func isBatchRunning(articleID: UUID) -> Bool { batchTasks[articleID] != nil }

    public func batchExplainAll(articleID: UUID) { startBatch(articleID, kind: .explain) }
    public func batchTranslateAll(articleID: UUID) { startBatch(articleID, kind: .translate) }

    public func cancelBatch(articleID: UUID) {
        batchTasks[articleID]?.cancel()
        batchTasks[articleID] = nil
        batchByArticle[articleID] = nil
    }

    private func startBatch(_ articleID: UUID, kind: BatchState.Kind) {
        guard batchTasks[articleID] == nil else { return }
        let pending = segments(for: articleID).filter { segment in
            switch kind {
            case .explain: return segment.explanation == nil
            case .translate: return segment.explanation == nil && segment.translation == nil
            }
        }.map(\.id)
        guard !pending.isEmpty else { return }

        // 无对应 provider 时不启动，直接把首句错误暴露给用户（设置未配模型）。
        let hasProvider = kind == .explain ? explanationProvider != nil : translationProvider != nil
        guard hasProvider else {
            if let first = pending.first { generationErrors[first] = .notConfigured }
            return
        }

        batchByArticle[articleID] = BatchState(
            kind: kind, completed: 0, total: pending.count, failed: 0)
        let concurrency = batchConcurrency
        batchTasks[articleID] = Task { [weak self] in
            await self?.runBatch(
                articleID: articleID, kind: kind, ids: pending, concurrency: concurrency)
        }
    }

    /// 分批并发：每批最多 `concurrency` 句同时在飞（各自在 await 网络时让出主线程）。
    /// 用非结构化 `Task { @MainActor }` 避免 TaskGroup 的 sending 约束（Swift 6）。
    private func runBatch(
        articleID: UUID, kind: BatchState.Kind, ids: [UUID], concurrency: Int
    ) async {
        var index = 0
        while index < ids.count {
            if Task.isCancelled { break }
            let chunk = ids[index..<min(index + concurrency, ids.count)]
            index += concurrency
            let tasks = chunk.map { segmentID in
                Task { @MainActor [weak self] () -> Bool in
                    guard let self, !Task.isCancelled else { return false }
                    return kind == .explain
                        ? await self.generateExplanation(articleID: articleID, segmentID: segmentID)
                        : await self.generateTranslation(articleID: articleID, segmentID: segmentID)
                }
            }
            for task in tasks {
                let ok = await task.value
                if var state = batchByArticle[articleID] {
                    state.completed += 1
                    if !ok { state.failed += 1 }
                    batchByArticle[articleID] = state
                }
            }
        }
        batchTasks[articleID] = nil
        batchByArticle[articleID] = nil
    }

    // MARK: - 生词收藏

    public func toggleFavorite(_ item: VocabularyItem, source article: Article) {
        if let index = favorites.firstIndex(where: { $0.word == item.word }) {
            let removed = favorites.remove(at: index)
            persist("removeFavorite") { [repository] in
                try await repository.deleteFavorite(id: removed.id)
            }
        } else {
            let favorite = FavoriteVocabulary(
                word: item.word,
                meaning: item.meaning,
                usage: item.usage,
                example: item.example,
                reading: item.reading,
                sourceArticleId: article.id,
                sourceArticleTitle: article.title,
                packIds: [WordPack.systemUngroupedID],
                dueDate: Self.localDateString()
            )
            favorites.insert(favorite, at: 0)
            persist("insertFavorite") { [repository] in
                try await repository.insertFavorite(favorite)
            }
        }
    }

    public func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        persist("removeFavorite") { [repository] in
            try await repository.deleteFavorite(id: id)
        }
    }

    /// 手动添加单词(规范 §1.4:与桌面一致按 normalized_word 全局去重)。
    /// - Returns: 是否添加成功;false = 已存在同词形卡片。
    @discardableResult
    public func addManualWord(
        word: String, meaning: String, reading: String?, usage: String?, example: String?,
        packIds: [UUID] = []
    ) -> Bool {
        let normalized = normalizedWord(word)
        guard !normalized.isEmpty, !meaning.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        if favorites.contains(where: { normalizedWord($0.word) == normalized }) {
            return false
        }
        let favorite = FavoriteVocabulary(
            word: word.trimmingCharacters(in: .whitespacesAndNewlines),
            meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines),
            usage: usage?.nilIfBlank,
            example: example?.nilIfBlank,
            reading: reading?.nilIfBlank,
            packIds: sanitizedPackIds(packIds),
            dueDate: Self.localDateString()
        )
        favorites.insert(favorite, at: 0)
        persist("insertFavorite") { [repository] in
            try await repository.insertFavorite(favorite)
        }
        return true
    }

    /// 编辑单词文本字段(词形变化时按 normalized_word 全局查重)。
    /// - Returns: 是否成功;false = 与其他卡片撞词形。
    @discardableResult
    public func updateFavorite(
        id: UUID, word: String, meaning: String, reading: String?, usage: String?, example: String?
    ) -> Bool {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return false }
        let normalized = normalizedWord(word)
        guard !normalized.isEmpty, !meaning.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        if favorites.contains(where: { $0.id != id && normalizedWord($0.word) == normalized }) {
            return false
        }
        favorites[index].word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].reading = reading?.nilIfBlank
        favorites[index].usage = usage?.nilIfBlank
        favorites[index].example = example?.nilIfBlank
        let updated = favorites[index]
        persist("updateFavorite") { [repository] in
            try await repository.updateFavorite(updated)
        }
        return true
    }

    /// 过滤到实际存在的词包;为空时归入系统默认"未分组"(规范 §1.2)。
    private func sanitizedPackIds(_ packIds: [UUID]) -> [UUID] {
        let known = Set(packs.map(\.id))
        var seen: Set<UUID> = []
        let valid = packIds.filter { known.contains($0) && seen.insert($0).inserted }
        return valid.isEmpty ? [WordPack.systemUngroupedID] : valid
    }

    /// 调整卡片的词包归属(整体替换;空选自动归入"未分组")。
    public func setPackIds(_ id: UUID, packIds: [UUID]) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let sanitized = sanitizedPackIds(packIds)
        guard Set(favorites[index].packIds) != Set(sanitized) else { return }
        favorites[index].packIds = sanitized
        persist("setPackIds") { [repository] in
            try await repository.setPackIds(vocabularyId: id, packIds: sanitized)
        }
        Task { await refreshStats() }
    }

    // MARK: - 词包管理(镜像桌面 create/update/delete_word_pack_cmd)

    /// 新建词包。- Returns: 成功创建的词包;名称为空返回 nil。
    @discardableResult
    public func createPack(name: String) -> WordPack? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pack = WordPack(name: trimmed, author: "user")
        packs.append(pack)
        persist("insertPack") { [repository] in
            try await repository.insertPack(pack)
        }
        return pack
    }

    /// 重命名词包(系统包不可改)。
    @discardableResult
    public func renamePack(_ id: UUID, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = packs.firstIndex(where: { $0.id == id }),
              !packs[index].isSystem
        else { return false }
        packs[index].name = trimmed
        packs[index].updatedAt = .now
        let updated = packs[index]
        persist("updatePack") { [repository] in
            try await repository.updatePack(updated)
        }
        return true
    }

    /// 删除词包(系统包不可删):包内不再属于任何词包的卡片归入"未分组"。
    public func deletePack(_ id: UUID) {
        guard id != WordPack.systemUngroupedID,
              packs.contains(where: { $0.id == id })
        else { return }
        packs.removeAll { $0.id == id }
        for index in favorites.indices where favorites[index].packIds.contains(id) {
            favorites[index].packIds.removeAll { $0 == id }
            if favorites[index].packIds.isEmpty {
                favorites[index].packIds = [WordPack.systemUngroupedID]
            }
        }
        if activePackId == id {
            activePackId = nil
        }
        persist("deletePack") { [repository] in
            try await repository.deletePack(id: id)
        }
        Task { await refreshStats() }
    }

    /// 标记已掌握 / 恢复复习(规范 §3):FSRS 状态不动。
    public func setSuspended(_ id: UUID, suspended: Bool) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[index].suspendedAt = suspended ? .now : nil
        persist("setSuspended") { [repository] in
            try await repository.setSuspended(id: id, suspended: suspended)
        }
        Task { await refreshStats() }
    }

    // MARK: - 复习(FSRS)

    /// 今日到期队列(按当前选中词包过滤,nil = 全部;规范 §3)。
    public func dueQueue() async -> [FavoriteVocabulary] {
        do {
            return try await repository.dueQueue(
                packId: activePackId,
                dateLocal: Self.localDateString(),
                newLimit: Self.dailyNewLimit,
                reviewLimit: Self.dailyReviewLimit
            )
        } catch {
            Self.logger.error("dueQueue failed: \(error)")
            return []
        }
    }

    /// 复习一张卡:FSRS 更新 + 卡片落盘 + 追加不可变复习事件(规范 §2.5 / §1.3)。
    public func review(_ id: UUID, grade: FSRS.Grade) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        var favorite = favorites[index]
        let now = Date.now
        let dateLocal = Self.localDateString(now)
        let previousState = favorite.srsState
        let elapsed = favorite.stability == 0 && favorite.difficulty == 0
            ? 0
            : Self.elapsedDays(for: favorite, reviewDate: now)

        let update: FSRS.Update
        do {
            update = try FSRS.nextReview(
                stability: favorite.stability,
                difficulty: favorite.difficulty,
                elapsedDays: elapsed,
                grade: grade,
                desiredRetention: Self.desiredRetention
            )
        } catch {
            Self.logger.error("FSRS nextReview failed: \(error)")
            return
        }

        favorite.srsState = update.state
        favorite.stability = update.stability
        favorite.difficulty = update.difficulty
        favorite.schedulerVersion = FSRS.schedulerVersion
        favorite.dueDate = Self.localDateString(
            Calendar.current.date(byAdding: .day, value: update.intervalDays, to: now) ?? now)
        favorite.lastReviewedAt = now
        favorite.reviewCount += 1
        favorites[index] = favorite

        let event = ReviewEvent(
            vocabularyId: favorite.id,
            reviewedAt: now,
            dateLocal: dateLocal,
            grade: grade.rawValue,
            elapsedDays: elapsed,
            previousState: previousState,
            schedulerVersion: FSRS.schedulerVersion,
            desiredRetention: Self.desiredRetention,
            resultStability: update.stability,
            resultDifficulty: update.difficulty,
            resultIntervalDays: update.intervalDays,
            resultState: update.state
        )
        let updated = favorite
        persist("applyReview") { [repository] in
            try await repository.applyReview(updated, event: event)
        }
        Task { await refreshStats() }
    }

    public func refreshStats() async {
        do {
            reviewStats = try await repository.reviewStats(
                packId: activePackId, dateLocal: Self.localDateString())
        } catch {
            Self.logger.error("reviewStats failed: \(error)")
        }
    }

    // MARK: - 阅读时长 / 统计分析

    /// 记录一次阅读会话(阅读器计时落盘；失败仅日志，不影响阅读)。
    public func recordReadingSession(articleId: UUID?, seconds: Int, startedAt: Date) async {
        let session = ReadingSession(
            articleId: articleId,
            dateLocal: Self.localDateString(startedAt),
            startedAt: startedAt,
            seconds: seconds)
        do {
            try await repository.recordReadingSession(session)
        } catch {
            Self.logger.error("recordReadingSession failed: \(error)")
        }
    }

    /// 统计分析全局聚合(独立于 activePackId)。统计 Tab 出现时刷新。
    public func refreshStatistics() async {
        do {
            statistics = try await repository.statistics(
                packId: nil, dateLocal: Self.localDateString(),
                rangeDays: Self.statsRangeDays, forecastDays: Self.statsForecastDays)
        } catch {
            Self.logger.error("statistics failed: \(error)")
        }
    }

    // MARK: - 本地日期(规范 §2.7:elapsed 按本地日期差)

    static func localDateString(_ date: Date = .now) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func elapsedDays(for favorite: FavoriteVocabulary, reviewDate: Date) -> Int {
        guard let last = favorite.lastReviewedAt else { return 0 }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: last)
        let to = calendar.startOfDay(for: reviewDate)
        return max(calendar.dateComponents([.day], from: from, to: to).day ?? 0, 0)
    }

    // MARK: - 落库串行链

    private func persist(
        _ label: String, _ operation: @escaping @Sendable () async throws -> Void
    ) {
        let previous = persistChain
        persistChain = Task { [weak self] in
            await previous?.value
            do {
                try await operation()
            } catch {
                Self.logger.error("persist \(label) failed: \(error)")
                self?.lastPersistenceFailure = "\(label): \(error)"
            }
        }
    }

    /// 等待所有已入队的落库操作完成（测试与退出前收尾用）。
    public func flushPersistence() async {
        await persistChain?.value
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
