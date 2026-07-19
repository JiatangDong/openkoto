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
                if let envelope = await envelope(from: provider, note: note) {
                    try? inbox.write(envelope)
                }
            }
        }
    }

    /// 优先识别 URL（网页分享），否则识别纯文本（选中文字分享）。
    private func envelope(from provider: NSItemProvider, note: String?) async -> ImportEnvelope? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider) {
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
