#if os(iOS)
import Foundation
import OKModels
import SwiftUI
import UniformTypeIdentifiers

/// 传输包的文件类型与 `fileExporter` 载体。
enum TransferFile {
    /// 导入允许的类型。
    ///
    /// 除了自家的 `com.openkoto.transfer`，还兜底放行 `.json`：
    /// 微信、邮件这类中转会把未知扩展名改写成 `.json` 或干脆丢掉扩展名，
    /// 只认自家 UTI 的话用户会看到一个选不中的灰文件，却完全不知道为什么。
    /// 内容真伪由 `TransferBundle.decode` 的 `format` 字段判定，不靠扩展名。
    static var readableContentTypes: [UTType] {
        var types: [UTType] = []
        if let own = UTType(TransferBundle.contentTypeIdentifier) { types.append(own) }
        if let byExtension = UTType(filenameExtension: TransferBundle.fileExtension),
            !types.contains(byExtension)
        {
            types.append(byExtension)
        }
        types.append(.json)
        return types
    }

    static var exportContentType: UTType {
        UTType(TransferBundle.contentTypeIdentifier) ?? .json
    }
}

/// `fileExporter` 要求的文档载体。
struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [TransferFile.exportContentType] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
