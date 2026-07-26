import AVFoundation
import Foundation

/// 从视频/音频容器里抽出一条可直接喂给语音识别的音轨。
///
/// 这是端上转写最容易漏掉的一步：`AVAudioFile` 读不了 mp4/mov 容器，
/// 必须先解出音频。**也是整条链路真正的内存风险所在**——分析本身是流式的，
/// 抽取才是会把整个文件读进内存的地方。所以一律走 `AVAssetExportSession`
/// 写盘，绝不 `Data(contentsOf:)`。
public enum AudioExtractor {
    public enum Failure: Error, Equatable {
        case noAudioTrack
        case exportFailed(String)
        case cancelled
    }

    /// 抽取结果。`duration` 顺带带出来，省得调用方再 load 一次。
    public struct Extracted: Sendable {
        public var url: URL
        public var duration: Double
    }

    /// - Parameters:
    ///   - source: 视频或音频文件
    ///   - destination: 目标 m4a 路径（已存在会被覆盖）
    public static func extract(from source: URL, to destination: URL) async throws -> Extracted {
        let asset = AVURLAsset(url: source)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw Failure.noAudioTrack }

        let duration = try await asset.load(.duration)
        let seconds = duration.isNumeric ? duration.seconds : 0

        // 已经是纯音频且格式合适时直接用原文件，省一次全量转码
        if try await asset.loadTracks(withMediaType: .video).isEmpty,
            Self.directlyReadableExtensions.contains(source.pathExtension.lowercased())
        {
            return Extracted(url: source, duration: seconds)
        }

        guard
            let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw Failure.exportFailed("cannot create export session")
        }
        try? FileManager.default.removeItem(at: destination)

        if #available(iOS 18, macOS 15, *) {
            do {
                try await session.export(to: destination, as: .m4a)
            } catch is CancellationError {
                throw Failure.cancelled
            } catch {
                throw Failure.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = destination
            session.outputFileType = .m4a
            await session.export()
            switch session.status {
            case .completed: break
            case .cancelled: throw Failure.cancelled
            default:
                throw Failure.exportFailed(
                    session.error?.localizedDescription ?? "export status \(session.status.rawValue)")
            }
        }
        return Extracted(url: destination, duration: seconds)
    }

    /// `AVAudioFile` 能直接打开的容器，不必再转一道。
    private static let directlyReadableExtensions: Set<String> = [
        "m4a", "aac", "wav", "aif", "aiff", "caf", "mp3",
    ]
}
