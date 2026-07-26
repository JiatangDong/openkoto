#if os(iOS)
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 从相册取出的视频。
///
/// 相册里的资源**不能长期引用**（`PHPicker` 给的是一次性副本，URL 出了作用域就没了），
/// 所以这里必须把它落到我们自己的临时目录，再由 `ContentStore` 移进 `Media/<id>/`。
/// 这也是相册路径与「文件」App 路径的唯一区别——后者存 bookmark 零拷贝。
///
/// `PhotosPicker` 走的是 out-of-process 的 `PHPickerViewController`，
/// **不需要 `NSPhotoLibraryUsageDescription`**，也不会弹相册权限——
/// 用户选了哪个，App 才拿得到哪个。凭空加权限声明只会招审核提问。
struct PhotoLibraryVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // received.file 在闭包返回后就会被系统删掉，必须先拷出来
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PhotoLibraryVideo(url: destination)
        }
    }
}
#endif
