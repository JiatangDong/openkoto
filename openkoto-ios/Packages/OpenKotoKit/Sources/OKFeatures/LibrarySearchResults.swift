#if os(iOS)
import OKDesignSystem
import OKLocalization
import OKModels
import SwiftUI

/// 书库搜索结果。
///
/// 两段式：上段是标题匹配（纯内存过滤，随输入即时出结果），下段是全文命中
/// （走 FTS，异步）。分开是因为两者的延迟差一个数量级——如果混在一起排序，
/// 用户会看到已经显示的标题结果被重排，那比慢更难受。
struct LibrarySearchResults: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.okCanvas) private var canvas

    let query: String
    let items: [LibraryItem]
    /// 点全文命中：解析出句序后由外层推导航。解析要触发懒切分，所以是 async。
    let onOpen: (ContentStore.SearchHit) async -> Void

    @State private var hits: [ContentStore.SearchHit] = []
    @State private var isSearching = false
    /// 正在解析落点的那条——避免用户以为点了没反应（懒切分一本大书要小几百毫秒）。
    @State private var openingID: UUID?

    /// 标题匹配：大小写不敏感的包含。
    private var titleMatches: [LibraryItem] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        return items.filter { $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if store.pendingIndexCount > 0 {
                indexingNotice
            }
            if !titleMatches.isEmpty {
                Section(L("search.section.titles")) {
                    ForEach(titleMatches) { item in
                        NavigationLink(value: LibraryRoute.item(item)) {
                            Label(item.title, systemImage: item.symbolName)
                        }
                    }
                }
            }
            Section(L("search.section.fullText")) {
                if isSearching && hits.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(L("search.searching")).foregroundStyle(theme.mutedForeground)
                    }
                } else if hits.isEmpty {
                    Text(L("search.noResults")).foregroundStyle(theme.mutedForeground)
                } else {
                    ForEach(hits) { hit in
                        Button {
                            open(hit)
                        } label: {
                            hitRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // 搜索命中是整行文字（标题 + 命中片段），不是卡片，所以限宽而不是铺成网格。
        .frame(maxWidth: canvas.isWide ? 860 : .infinity)
        .frame(maxWidth: .infinity)
        .background(theme.background)
        // 输入变化就重跑：`.task(id:)` 会取消上一次，前缀查询不会互相覆盖结果。
        .task(id: query) {
            isSearching = true
            defer { isSearching = false }
            // 去抖：连打时不给每个中间态都发一次查询。
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            hits = await store.search(query)
            // 顺便刷新回填进度：只在启动时查一次的话，索引早就建完了
            // "正在建立索引"还挂在那儿，读数也永远停在升级那一刻。
            await store.refreshIndexingProgress()
        }
    }

    private var indexingNotice: some View {
        Label(
            L("search.indexing\(store.pendingIndexCount)"),
            systemImage: "clock.arrow.circlepath"
        )
        .font(.footnote)
        .foregroundStyle(theme.mutedForeground)
    }

    private func hitRow(_ hit: ContentStore.SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(sourceLabel(for: hit))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                Spacer(minLength: 0)
                if openingID == hit.id { ProgressView().controlSize(.mini) }
            }
            Text(highlighted(hit.snippet))
                .font(.callout)
                .foregroundStyle(theme.foreground)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// 来源要说清是哪本书的哪一章——只显示章标题的话，一本书里几十条命中会长得一模一样。
    private func sourceLabel(for hit: ContentStore.SearchHit) -> String {
        switch store.container(forArticle: hit.articleID) {
        case .book(let book, _): "\(book.title) · \(hit.title)"
        case .media(let media): "\(media.title)"
        case .article, .unknown: hit.title
        }
    }

    /// 把控制符标记转成加粗高亮。
    private func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var isMatch = false
        for piece in snippet.split(
            omittingEmptySubsequences: false,
            whereSeparator: {
                $0 == Character(ContentStore.SearchHit.highlightStart)
                    || $0 == Character(ContentStore.SearchHit.highlightEnd)
            })
        {
            var run = AttributedString(String(piece))
            if isMatch {
                run.font = .callout.bold()
                run.foregroundColor = theme.primary
            }
            result += run
            isMatch.toggle()
        }
        return result
    }

    private func open(_ hit: ContentStore.SearchHit) {
        guard openingID == nil else { return }
        openingID = hit.id
        Task {
            await onOpen(hit)
            openingID = nil
        }
    }
}
#endif
