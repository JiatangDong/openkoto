#if os(iOS)
import SwiftUI
import OKModels
import OKBooks
import OKDesignSystem
import OKLocalization

/// 书库列表项：单篇文章与整本书混排，按创建时间倒序。
enum LibraryItem: Identifiable, Hashable {
    case article(Article)
    case book(Book)

    var id: UUID {
        switch self {
        case .article(let article): article.id
        case .book(let book): book.id
        }
    }

    var createdAt: Date {
        switch self {
        case .article(let article): article.createdAt
        case .book(let book): book.createdAt
        }
    }
}

/// 书库：文章/书籍卡片列表 + 导入入口（设计文档 §6.2）。
struct LibraryView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showImport = false
    @State private var path: [LibraryItem] = []
    @State private var importError: String?
    @State private var isImportingBook = false

    /// 文章与书籍混排，按创建时间倒序。
    private var items: [LibraryItem] {
        let merged = store.articles.map(LibraryItem.article)
            + store.books.map(LibraryItem.book)
        return merged.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        L("library.empty.title"),
                        systemImage: "book",
                        description: Text(L("library.empty.message"))
                    )
                } else {
                    articleList
                }
            }
            .background(theme.background)
            // 从"文件"App 或其他 App 拖入 .txt/.md/.epub 文件直接导入
            .dropDestination(for: URL.self) { urls, _ in
                importDroppedFiles(urls)
            }
            .overlay {
                if isImportingBook {
                    // 解压 + 分章可能要几秒，给个明确的进行态，别让用户以为卡死。
                    ProgressView(L("import.book.parsing"))
                        .padding(24)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.sheet))
                        .shadow(radius: 12)
                }
            }
            .alert(
                L("import.book.failed"),
                isPresented: Binding(
                    get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                if let importError { Text(importError) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        Label(L("library.import"), systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportSheet()
            }
            .navigationDestination(for: LibraryItem.self) { item in
                switch item {
                case .article(let article): ReaderView(article: article)
                case .book(let book): BookReaderView(book: book)
                }
            }
        }
        .onAppear { openFirstArticleForDemoIfNeeded() }
        // 数据经 GRDB 异步加载，onAppear 时可能尚未就绪，加载完成后再试一次
        .onChange(of: store.articles.first?.id) { openFirstArticleForDemoIfNeeded() }
    }

    /// 截图/UI 测试用（-prototypeDemo）：直接打开第一篇示例文章
    private func openFirstArticleForDemoIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-prototypeDemo"),
              path.isEmpty, let first = store.articles.first
        else { return }
        path = [.article(first)]
    }

    /// 拖入文件导入：按扩展名分流——EPUB 走书籍管线，文本够长也建书，否则单篇文章。
    @discardableResult
    private func importDroppedFiles(_ urls: [URL]) -> Bool {
        var handled = false
        for url in urls {
            handled = true
            Task { await importFile(url) }
        }
        return handled
    }

    /// 统一的文件导入入口。
    /// EPUB 必然走书籍；文本先试书籍（够长且能分章），不成再退回单篇文章。
    private func importFile(_ url: URL) async {
        isImportingBook = true
        defer { isImportingBook = false }
        do {
            if try await store.importBook(from: url) != nil { return }
        } catch {
            importError = Self.message(for: error)
            return
        }
        // 不够成书：按普通文章导入（与既有行为一致）。
        guard let parsed = try? TextImport.readTextFile(at: url),
            !parsed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        store.importArticle(title: parsed.title, content: parsed.content)
    }

    static func message(for error: Error) -> String {
        guard let failure = error as? BookImporter.Failure else {
            return error.localizedDescription
        }
        switch failure {
        case .drmProtected: return L("import.error.drm")
        case .corruptArchive: return L("import.error.corruptArchive")
        case .emptyContent: return L("import.error.emptyContent")
        case .unsupportedFormat: return L("import.error.unsupportedFormat")
        }
    }

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        switch item {
                        case .article(let article): ArticleCard(article: article)
                        case .book(let book): BookCard(book: book)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            switch item {
                            case .article(let article): store.deleteArticle(article.id)
                            case .book(let book): store.deleteBook(book.id)
                            }
                        } label: {
                            Label(L("common.delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

private struct ArticleCard: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme

    let article: Article

    var body: some View {
        let progress = store.progress(for: article.id)
        ThemedCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(theme.cardForeground)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Text(article.createdAt, style: .date)
                    Label("\(progress.total)", systemImage: "text.alignleft")
                    Spacer()
                    if progress.total > 0 {
                        explainedBadge(progress)
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    @ViewBuilder
    private func explainedBadge(_ progress: (explained: Int, total: Int)) -> some View {
        if progress.explained > 0 {
            Text("\(progress.explained)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    theme.explained.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(theme.explained)
        }
    }
}

/// 导入 sheet：粘贴文本 / 本地文件（.txt/.md）/ 网页抓取（设计文档 §6.3）。
/// 文件与网址导入解析后填入同一编辑区，用户可复核再保存。
private struct ImportSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private enum Mode: String, CaseIterable, Identifiable {
        case paste, file, url
        var id: String { rawValue }
        var titleKey: String.LocalizationValue {
            switch self {
            case .paste: "import.method.paste"
            case .file: "import.method.file"
            case .url: "import.method.url"
            }
        }
    }

    @State private var mode: Mode = .paste
    @State private var title = ""
    @State private var content = ""
    @State private var urlText = ""
    @State private var isFileImporterPresented = false
    @State private var isFetching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text(L($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch mode {
                case .file: fileSection
                case .url: urlSection
                case .paste: EmptyView()
                }

                editorSection
            }
            .navigationTitle(L("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: TextImport.readableContentTypes + TextImport.bookContentTypes
            ) { result in
                handleFileImport(result)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(
                L("import.url.failed"),
                isPresented: Binding(
                    get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
        }
    }

    private var fileSection: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            Label(L("import.file.bookButton"), systemImage: "doc.badge.plus")
        }
    }

    private var urlSection: some View {
        HStack {
            TextField(L("import.url.placeholder"), text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if isFetching {
                ProgressView()
            } else {
                Button(L("import.url.fetch")) { fetchURL() }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var editorSection: some View {
        Section {
            TextField(L("import.field.title"), text: $title)
            TextEditor(text: $content)
                .frame(minHeight: 200)
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text(L("import.field.content"))
                            .foregroundStyle(theme.mutedForeground)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// EPUB 与长文本直接建书（不进编辑区——几十万字没法复核）；
    /// 短文本仍填入编辑区，保持原有"导入前可改标题正文"的体验。
    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    if try await store.importBook(from: url) != nil {
                        dismiss()
                        return
                    }
                } catch {
                    errorMessage = LibraryView.message(for: error)
                    return
                }
                do {
                    let parsed = try TextImport.readTextFile(at: url)
                    title = parsed.title
                    content = parsed.content
                    mode = .paste
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func fetchURL() {
        isFetching = true
        errorMessage = nil
        Task {
            defer { isFetching = false }
            do {
                let result = try await TextImport.fetchArticle(from: urlText)
                title = result.title
                content = result.content
                mode = .paste
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func save() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = title.isEmpty
            ? String(trimmed.prefix(while: { !$0.isNewline }).prefix(40))
            : title
        store.importArticle(title: finalTitle, content: trimmed)
        dismiss()
    }
}
#endif
