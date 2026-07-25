import Social
import UIKit
import UniformTypeIdentifiers
import OKModels

/// 分享扩展：把用户从 Safari / 其他 App 分享的网址或选中文本，作为 `ImportEnvelope`
/// 原子写入 App Group 收件箱（设计文档 §6.3）。扩展**不**访问主库、不做 AI/切分——
/// 主 App 下次激活时 `ShareInbox.drain()` 读取并导入。
final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        let note = contentText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task {
            await handle(items: items, note: note?.isEmpty == false ? note : nil)
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func handle(items: [NSExtensionItem], note: String?) async {
        guard let inbox = ShareInbox() else { return }
        for item in items {
            for provider in item.attachments ?? [] {
                if let envelope = await envelope(from: provider, note: note, inbox: inbox) {
                    try? inbox.write(envelope)
                }
            }
        }
    }

    /// 识别顺序：书籍文件 → 网页 URL → 纯文本。
    ///
    /// 书籍文件先于 URL 判断——文件分享过来时 provider 同时符合 `public.url`
    /// （file URL 也是 URL），按 URL 处理会当成网页去抓取。
    private func envelope(
        from provider: NSItemProvider, note: String?, inbox: ShareInbox
    ) async -> ImportEnvelope? {
        if let envelope = await fileEnvelope(from: provider, inbox: inbox) { return envelope }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider), !url.isFileURL {
            return ImportEnvelope(
                payload: .url(url.absoluteString, title: nil, text: note),
                sourceApp: "share-extension")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider) {
            return ImportEnvelope(payload: .plainText(text), sourceApp: "share-extension")
        }
        return nil
    }

    /// 扩展进程结束后临时文件就没了，必须先拷进 App Group 容器。
    private func fileEnvelope(
        from provider: NSItemProvider, inbox: ShareInbox
    ) async -> ImportEnvelope? {
        let bookTypes = [UTType.epub, UTType.plainText, UTType.text]
        guard let type = bookTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }),
            let source = await loadFileURL(provider, type: type),
            source.isFileURL
        else { return nil }

        let ext = source.pathExtension.isEmpty ? "txt" : source.pathExtension
        // EPUB 才值得走文件通道；纯文本仍按文本信封传，省一次拷贝。
        guard ext.lowercased() == "epub" else { return nil }

        do {
            let blobs = try inbox.blobsDirectory()
            let name = "\(UUID().uuidString).\(ext)"
            let destination = blobs.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            return ImportEnvelope(
                payload: .file(
                    relativePath: "blobs/\(name)",
                    filename: source.lastPathComponent,
                    uti: type.identifier),
                sourceApp: "share-extension")
        } catch {
            return nil
        }
    }

    private func loadFileURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.plainText.identifier, options: nil
            ) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
