#if os(iOS)
import SwiftUI
import WebKit
import OKModels
import OKDesignSystem

/// 原版模式：用 `WKWebView` 直接加载章节 XHTML，原书 CSS / 字体 / 图片 / 竖排全部保留。
///
/// 不引 epub.js——ZIP 与 spine 我们已经自己解完了，直接给 WebView 一个文件 URL 即可，
/// 省掉一整套 JS 依赖、iframe 沙盒和跨帧取选区的麻烦。
struct OriginalLayoutView: UIViewRepresentable {
    /// 当前章节文件（书籍目录内）。
    let chapterURL: URL
    /// 允许 WebView 读取的根目录——CSS/字体/图片都靠它解析相对路径。
    let bookDirectory: URL
    let fontScale: Double
    /// 载入完成后滚到的阅读进度（0 = 阅读顺序起点，竖排已在 JS 里换算）。
    var restoreFraction: Double = 0
    /// 本章需要重放的划线：(定位符, 原文)。
    var highlights: [(locator: String?, text: String?)] = []
    var backgroundColor: Color = .clear
    var onScroll: ((Double) -> Void)?
    var onSelection: ((WebSelection?) -> Void)?
    /// 站内链接跳转（目录、注释回跳）交回 SwiftUI 处理。
    var onNavigate: ((URL) -> Void)?

    struct WebSelection: Equatable {
        var text: String
        var locator: String
        /// WebView 坐标系里的选区矩形，用于给原生浮层定位。
        var rects: [CGRect]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "okoto")
        if let script = Self.bridgeScript {
            controller.addUserScript(
                WKUserScript(
                    source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // 本地书籍不需要任何网络内容；也不该给它 cookie/存储。
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        context.coordinator.load(chapterURL, in: webView, allowing: bookDirectory)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(chapterURL, in: webView, allowing: bookDirectory)
        // 字号走 pageZoom，不去改书自己的 CSS——改了就不叫"原版"了。
        webView.pageZoom = CGFloat(fontScale)
    }

    static let bridgeScript: String? = {
        guard let url = Bundle.module.url(forResource: "OKReaderBridge", withExtension: "js")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: OriginalLayoutView
        private var loadedURL: URL?

        init(_ parent: OriginalLayoutView) {
            self.parent = parent
        }

        func load(_ url: URL, in webView: WKWebView, allowing directory: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            // 换章/切模式后要恢复到上次读到的位置，标记一次待恢复。
            pendingRestore = parent.restoreFraction
            webView.loadFileURL(url, allowingReadAccessTo: directory)
        }

        /// 待恢复的进度。只在载入完成后用一次，之后由用户滚动接管。
        private var pendingRestore: Double?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyHighlights(in: webView)
            guard let fraction = pendingRestore, fraction > 0 else {
                pendingRestore = nil
                return
            }
            pendingRestore = nil
            // 等排版稳定再滚——刚 didFinish 时 scrollHeight 还可能在变。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak webView] in
                webView?.evaluateJavaScript("OK.scrollToFraction(\(fraction));")
            }
        }

        /// 载入完成后重放划线。
        func applyHighlights(in webView: WKWebView) {
            let payload = parent.highlights.map { entry -> [String: String] in
                var dictionary: [String: String] = [:]
                if let locator = entry.locator { dictionary["locator"] = locator }
                if let text = entry.text { dictionary["text"] = text }
                return dictionary
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
            else { return }
            let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("OK.applyMarks('\(escaped)');")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // 首次加载放行。
            if navigationAction.navigationType == .other, url == loadedURL {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL {
                // 站内跳转（目录/注释）：交回 SwiftUI 切章，不让 WebView 自己导航——
                // 否则阅读位置与章节状态会和界面脱节。
                decisionHandler(.cancel)
                parent.onNavigate?(url)
                return
            }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            decisionHandler(.cancel)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                let name = body["name"] as? String
            else { return }
            let payload = body["payload"] as? [String: Any] ?? [:]

            switch name {
            case "scroll":
                guard let fraction = payload["fraction"] as? Double else { return }
                parent.onScroll?(fraction)
            case "selection":
                guard let text = payload["text"] as? String,
                    let locator = payload["locator"] as? String
                else { return }
                let rects = (payload["rects"] as? [[String: Any]] ?? []).compactMap {
                    rect -> CGRect? in
                    guard let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                        let width = rect["width"] as? Double,
                        let height = rect["height"] as? Double
                    else { return nil }
                    return CGRect(x: x, y: y, width: width, height: height)
                }
                parent.onSelection?(WebSelection(text: text, locator: locator, rects: rects))
            case "selectionCleared":
                parent.onSelection?(nil)
            default:
                break
            }
        }
    }
}
#endif
