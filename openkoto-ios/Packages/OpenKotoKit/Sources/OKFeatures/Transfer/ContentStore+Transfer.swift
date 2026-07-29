#if os(iOS)
import Foundation
import OKModels
import OKPersistence

/// 传输包的导入/导出（跨设备同步 P2）。
extension ContentStore {
    /// 导入结果或错误，供设置页原样展示。
    public enum TransferOutcome: Sendable {
        case imported(ImportResult)
        case failed(TransferFailure)
    }

    public enum TransferFailure: Error, Sendable, Equatable {
        case unreadable
        case notATransferBundle
        /// 文件比本 App 新。**必须原样保留文件**，别劝用户删——
        /// 升级之后它还能导进来。
        case appTooOld(fileVersion: Int, supported: Int)
        case malformed(String)
        case writeFailed(String)
    }

    /// 从用户挑中的文件导入。
    public func importTransferFile(at url: URL) async -> TransferOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            return .failed(.unreadable)
        }
        return await importTransferData(data)
    }

    /// 从内存中的数据导入（分享扩展、粘贴、测试都走这里）。
    public func importTransferData(_ data: Data) async -> TransferOutcome {
        let bundle: TransferBundle
        do {
            bundle = try TransferBundle.decode(from: data)
        } catch let error as TransferBundle.DecodeError {
            switch error {
            case .notATransferBundle: return .failed(.notATransferBundle)
            case .unsupportedVersion(let found, let supported):
                return .failed(.appTooOld(fileVersion: found, supported: supported))
            case .malformed(let detail): return .failed(.malformed(detail))
            }
        } catch {
            return .failed(.malformed("\(error)"))
        }

        do {
            // 水位线的回拨在 `importTransferBundle` 内部、与导入同事务完成
            // （导入保留了来源端的 updatedAt，可能比水位线还旧，不回拨就永远推不上云）。
            let result = try await repository.importTransferBundle(bundle)
            await load()
            return .imported(result)
        } catch {
            // 失败详情直接回给用户（下面 .writeFailed 会展示），
            // 不写 lastPersistenceFailure：那个标记是给"后台静默失败"用的，
            // 而导入是用户主动发起、当场就能看到结果的操作。
            Self.logger.error("import failed: \(error)")
            return .failed(.writeFailed("\(error)"))
        }
    }

    /// 把本地库导出成传输包。
    ///
    /// - Parameter includeContent: 带上文章与精讲。词库通常几百 KB，
    ///   而全部正文＋精讲可能几十 MB，让用户自己选。
    public func exportTransferData(includeContent: Bool) async -> Result<Data, TransferFailure> {
        do {
            let bundle = try await repository.exportTransferBundle(includeContent: includeContent)
            return .success(try bundle.encoded())
        } catch {
            Self.logger.error("export failed: \(error)")
            return .failure(.writeFailed("\(error)"))
        }
    }
}
#endif
