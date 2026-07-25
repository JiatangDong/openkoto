import Foundation
import GRDB
import Testing
import OKModels

@testable import OKPersistence

/// 书籍表与 BookRepository 的事务测试。
/// 重点在两条无法用外键表达、只能靠代码保证的规则：
/// 删书要级联到章节 article，且删完之后生词的标题快照必须还在。
@Suite struct BookRepositoryTests {
    private func makeRepositories() throws -> (BookRepository, ContentRepository, AppDatabase) {
        let database = try AppDatabase.inMemory()
        return (BookRepository(database: database), ContentRepository(database: database), database)
    }

    private func makeBook(title: String = "吾輩は猫である") -> Book {
        Book(
            title: title, author: "夏目漱石", language: "ja", format: .epub,
            dirName: UUID().uuidString, opfPath: "OEBPS/content.opf", totalChars: 1234,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 造 n 章：每章一个 article 行 + 一条归属行。
    private func makeChapters(
        book: Book, titles: [String]
    ) -> [(article: Article, chapter: BookChapter)] {
        titles.enumerated().map { index, title in
            let article = Article(
                title: title, content: "\(title)的正文内容。", sourceType: .article,
                createdAt: book.createdAt)
            return (
                article,
                BookChapter(
                    articleId: article.id, bookId: book.id, index: index,
                    sourceHref: "OEBPS/ch\(index).xhtml", charCount: 100 + index)
            )
        }
    }

    // MARK: - 导入与查询

    @Test func insertBookRoundTripsMetadataAndChapters() async throws {
        let (books, _, _) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章", "第二章", "第三章"])
        try await books.insertBook(book, chapters: chapters)

        let loaded = try #require(await books.loadBooks().first)
        #expect(loaded == book)

        let summaries = try await books.chapterSummaries(bookID: book.id)
        #expect(summaries.map(\.title) == ["第一章", "第二章", "第三章"])
        #expect(summaries.map(\.index) == [0, 1, 2])
        #expect(summaries.map(\.charCount) == [100, 101, 102])
        // 导入不切句，摘要里 isSegmented 全 false。
        #expect(summaries.allSatisfy { !$0.isSegmented })
    }

    /// 章节虽然也是 article 行，但不能出现在书库顶层列表里。
    @Test func loadAllExcludesBookChapters() async throws {
        let (books, content, _) = try makeRepositories()
        let plain = Article(title: "普通文章", content: "正文")
        try await content.insertArticle(plain, segments: [])

        let book = makeBook()
        try await books.insertBook(
            book, chapters: makeChapters(book: book, titles: ["第一章", "第二章"]))

        let snapshot = try await content.loadAll()
        #expect(snapshot.articles.map(\.id) == [plain.id])
    }

    @Test func chapterLookupReturnsOwnership() async throws {
        let (books, _, _) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章", "第二章"])
        try await books.insertBook(book, chapters: chapters)

        let chapter = try #require(await books.chapter(articleID: chapters[1].article.id))
        #expect(chapter.bookId == book.id)
        #expect(chapter.index == 1)
        #expect(chapter.sourceHref == "OEBPS/ch1.xhtml")
        #expect(try await books.chapter(articleID: UUID()) == nil)
    }

    // MARK: - 延迟切分

    @Test func replaceSegmentsMarksChapterSegmented() async throws {
        let (books, content, _) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章"])
        try await books.insertBook(book, chapters: chapters)
        let articleID = chapters[0].article.id

        #expect(try await content.loadSegments(articleID: articleID).isEmpty)

        let segments = ["一句目。", "二句目。"].enumerated().map { index, text in
            ArticleSegment(articleId: articleID, order: index, text: text)
        }
        try await content.replaceSegments(articleID: articleID, segments: segments)

        #expect(try await content.loadSegments(articleID: articleID).map(\.text)
            == ["一句目。", "二句目。"])
        #expect(try #require(await books.chapter(articleID: articleID)).isSegmented)
    }

    /// 重复切分要幂等：旧句先删再插，不会因 UNIQUE(article_id, order_index) 冲突。
    @Test func replaceSegmentsIsIdempotent() async throws {
        let (books, content, _) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章"])
        try await books.insertBook(book, chapters: chapters)
        let articleID = chapters[0].article.id

        let segments = ["一句目。"].enumerated().map { index, text in
            ArticleSegment(articleId: articleID, order: index, text: text)
        }
        try await content.replaceSegments(articleID: articleID, segments: segments)
        try await content.replaceSegments(articleID: articleID, segments: segments)
        #expect(try await content.loadSegments(articleID: articleID).count == 1)
    }

    // MARK: - 删书级联

    @Test func deleteBookCascadesChaptersAndSegments() async throws {
        let (books, content, database) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章", "第二章"])
        try await books.insertBook(book, chapters: chapters)
        try await content.replaceSegments(
            articleID: chapters[0].article.id,
            segments: [ArticleSegment(articleId: chapters[0].article.id, order: 0, text: "一句。")])

        try await books.deleteBook(id: book.id)

        #expect(try await books.loadBooks().isEmpty)
        let counts = try await database.writer.read { db in
            (
                articles: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") ?? -1,
                segments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segment") ?? -1,
                chapters: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_chapter") ?? -1
            )
        }
        #expect(counts.articles == 0)
        #expect(counts.segments == 0)
        #expect(counts.chapters == 0)
    }

    /// 删书后生词要保留标题快照——生词本里那条卡片不能变成无名氏。
    /// 这条靠 favorite_vocabulary.source_article_id 的 ON DELETE SET NULL 生效，
    /// 所以删除顺序必须是"先 article 后 book"。
    @Test func deleteBookNullsFavoriteSourceButKeepsTitleSnapshot() async throws {
        let (books, content, _) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章"])
        try await books.insertBook(book, chapters: chapters)

        let favorite = FavoriteVocabulary(
            word: "吾輩", meaning: "我",
            sourceArticleId: chapters[0].article.id,
            sourceArticleTitle: "吾輩は猫である · 第一章")
        try await content.insertFavorite(favorite)

        try await books.deleteBook(id: book.id)

        let reloaded = try #require(await content.loadAll().favorites.first)
        #expect(reloaded.sourceArticleId == nil)
        #expect(reloaded.sourceArticleTitle == "吾輩は猫である · 第一章")
    }

    @Test func deleteBookRemovesProgressAndMarks() async throws {
        let (books, _, database) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章"])
        try await books.insertBook(book, chapters: chapters)

        try await books.saveProgress(
            BookProgress(
                bookId: book.id, chapterArticleId: chapters[0].article.id,
                chapterIndex: 0, segmentOrder: 5, mode: .native))
        try await books.saveMark(
            BookMark(
                bookId: book.id, chapterArticleId: chapters[0].article.id,
                chapterIndex: 0, kind: .bookmark, segmentOrder: 5, selectedText: "吾輩"))

        try await books.deleteBook(id: book.id)

        let leftovers = try await database.writer.read { db in
            (
                progress: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_progress") ?? -1,
                marks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_mark") ?? -1
            )
        }
        #expect(leftovers.progress == 0)
        #expect(leftovers.marks == 0)
    }

    // MARK: - 阅读位置

    @Test func progressUpsertKeepsOneRowPerBook() async throws {
        let (books, _, database) = try makeRepositories()
        let book = makeBook()
        try await books.insertBook(book, chapters: makeChapters(book: book, titles: ["第一章"]))

        for order in 0..<5 {
            try await books.saveProgress(
                BookProgress(
                    bookId: book.id, chapterIndex: 1, segmentOrder: order,
                    scrollFraction: Double(order) / 10, mode: .native,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(order))))
        }

        let rows = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_progress") ?? -1
        }
        #expect(rows == 1)
        let progress = try #require(await books.loadProgress()[book.id])
        #expect(progress.segmentOrder == 4)
        #expect(progress.chapterIndex == 1)
    }

    /// 两个锚点同时维护，切模式时互相换算，任何时候都有落点。
    @Test func progressConvertsBetweenAnchors() {
        let native = BookProgress(bookId: UUID(), segmentOrder: 50, scrollFraction: nil)
        #expect(native.resolvedFraction(segmentCount: 100) == 0.5)
        #expect(native.resolvedSegmentOrder(segmentCount: 100) == 50)

        let original = BookProgress(bookId: UUID(), segmentOrder: nil, scrollFraction: 0.25)
        #expect(original.resolvedSegmentOrder(segmentCount: 100) == 25)
        #expect(original.resolvedFraction(segmentCount: 100) == 0.25)

        // 边界：空章、越界锚点都要收敛到合法下标。
        let empty = BookProgress(bookId: UUID(), segmentOrder: 10)
        #expect(empty.resolvedSegmentOrder(segmentCount: 0) == 0)
        #expect(empty.resolvedSegmentOrder(segmentCount: 3) == 2)
        let none = BookProgress(bookId: UUID())
        #expect(none.resolvedSegmentOrder(segmentCount: 10) == 0)
        #expect(none.resolvedFraction(segmentCount: 10) == 0)
    }

    // MARK: - 书签

    @Test func markCRUDRoundTrips() async throws {
        let (books, _, _) = try makeRepositories()
        let book = makeBook()
        let chapters = makeChapters(book: book, titles: ["第一章", "第二章"])
        try await books.insertBook(book, chapters: chapters)

        var highlight = BookMark(
            bookId: book.id, chapterArticleId: chapters[1].article.id, chapterIndex: 1,
            kind: .highlight, segmentOrder: 3, charStart: 0, charEnd: 2,
            locator: "OEBPS/ch1.xhtml#/2/4/1:0-1:2", scrollFraction: 0.3,
            selectedText: "吾輩", color: "yellow")
        try await books.saveMark(highlight)
        try await books.saveMark(
            BookMark(
                bookId: book.id, chapterIndex: 0, kind: .bookmark, segmentOrder: 1,
                selectedText: "开头"))

        let marks = try await books.marks(bookID: book.id)
        #expect(marks.count == 2)
        // 按章排序，便于书签面板分组展示。
        #expect(marks.map(\.chapterIndex) == [0, 1])

        highlight.note = "这里是伏笔"
        try await books.saveMark(highlight)
        let updated = try #require(await books.marks(bookID: book.id).first { $0.id == highlight.id })
        #expect(updated.note == "这里是伏笔")
        #expect(updated.kind == .highlight)
        #expect(updated.locator == "OEBPS/ch1.xhtml#/2/4/1:0-1:2")

        try await books.deleteMark(id: highlight.id)
        #expect(try await books.marks(bookID: book.id).count == 1)
    }

    // MARK: - 损坏行

    @Test func rejectsUnknownEnumValues() async throws {
        let (books, _, database) = try makeRepositories()
        let book = makeBook()
        try await books.insertBook(book, chapters: [])
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE book SET format = 'pdf'")
        }
        await #expect(throws: OKPersistence.PersistenceError.self) {
            try await books.loadBooks()
        }
    }
}
