#if os(iOS)
import SwiftUI
import OKModels
import OKDesignSystem
import OKLocalization

/// 书库：文章卡片列表 + 导入入口（设计文档 §6.2）。
struct LibraryView: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showImport = false
    @State private var path: [Article] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.articles.isEmpty {
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
            // 从"文件"App 或其他 App 拖入 .txt/.md 文件直接导入
            .dropDestination(for: URL.self) { urls, _ in
                importDroppedFiles(urls)
            }
            .navigationTitle("OpenKoto")
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
            .navigationDestination(for: Article.self) { article in
                ReaderView(article: article)
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
        path = [first]
    }

    /// 拖入文件导入：仅取可读文本文件，逐个切分入库；返回是否至少导入一篇。
    @discardableResult
    private func importDroppedFiles(_ urls: [URL]) -> Bool {
        var imported = false
        for url in urls {
            guard let parsed = try? TextImport.readTextFile(at: url),
                  !parsed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            store.importArticle(title: parsed.title, content: parsed.content)
            imported = true
        }
        return imported
    }

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.articles) { article in
                    NavigationLink(value: article) {
                        ArticleCard(article: article)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            store.deleteArticle(article.id)
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
                allowedContentTypes: TextImport.readableContentTypes
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
            Label(L("import.file.button"), systemImage: "doc.badge.plus")
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

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let parsed = try TextImport.readTextFile(at: url)
                title = parsed.title
                content = parsed.content
                mode = .paste
            } catch {
                errorMessage = error.localizedDescription
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
