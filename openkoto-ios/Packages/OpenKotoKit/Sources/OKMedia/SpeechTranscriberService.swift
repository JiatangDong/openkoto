#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// 端上语音识别 → `TimedToken`。
///
/// 需要 iOS 26 的 `SpeechAnalyzer`/`SpeechTranscriber`：它是唯一能**直接转写文件、
/// 无时长上限、且给词级时间戳**的系统 API。老的 `SFSpeechRecognizer` 约 1 分钟就断，
/// 且长文件里时间戳会中途归零——不要退回去用它，那条路是死的。
///
/// **绝不分片。** `analyzeSequence` 是流式的，单遍走完整个文件。
/// 桌面端「分片无重叠 → 跨界句子被物理劈成两半」的根因在这里由构造消失；
/// 任何「为了进度或断点续跑而分片」的想法都要拒绝，那是在重新发明那个 bug。
@available(iOS 26, *)
public actor SpeechTranscriberService {
    public enum Phase: Sendable, Equatable {
        /// 从视频容器里抽音轨。长视频的内存与耗时主要花在这。
        case preparingAudio
        /// 首次使用某语言要下模型，`Double` 是 0–1 进度。
        case downloadingModel(Double)
        /// 转写中，`Double` 是 0–1 进度。
        case transcribing(Double)
    }

    public enum Failure: Error, Equatable {
        case unsupportedLocale(String)
        case modelUnavailable(String)
        case transcriptionFailed(String)
        case emptyResult
    }

    public init() {}

    /// 该语种能不能在本机做端上转写。UI 用它决定要不要显示入口。
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public static func isSupported(_ locale: Locale) async -> Bool {
        let target = locale.identifier(.bcp47).lowercased()
        return await SpeechTranscriber.supportedLocales.contains {
            $0.identifier(.bcp47).lowercased() == target
        }
    }

    /// 转写一个媒体文件。
    ///
    /// - Parameters:
    ///   - mediaURL: 视频或音频
    ///   - audioDestination: 抽出的音轨落在哪（转写失败可重试，不必重抽）
    ///   - locale: 目标语种，必须在 `supportedLocales` 里
    public func transcribe(
        mediaURL: URL,
        audioDestination: URL,
        locale: Locale,
        onPhase: @Sendable @escaping (Phase) -> Void
    ) async throws -> [TimedToken] {
        guard await Self.isSupported(locale) else {
            throw Failure.unsupportedLocale(locale.identifier(.bcp47))
        }

        // ① 抽音轨
        onPhase(.preparingAudio)
        let audio = try await AudioExtractor.extract(from: mediaURL, to: audioDestination)
        try Task.checkCancellation()

        // ② 组装转写模块。attributeOptions 是拿词级时间戳的唯一开关；
        //    reportingOptions 不要 volatileResults——我们只关心最终结果，
        //    中间态只会让结果流里塞满要丢弃的东西。
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])

        // ③ 语言模型按需下载
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            {
                onPhase(.downloadingModel(0))
                try await request.downloadAndInstall()
                onPhase(.downloadingModel(1))
            }
        } catch {
            throw Failure.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        // ④ 分析。结果流必须与分析**并行**消费，否则背压会把两边一起卡死。
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audio.url)
        } catch {
            throw Failure.transcriptionFailed(error.localizedDescription)
        }

        let duration = audio.duration
        async let collected: [TimedToken] = {
            var tokens: [TimedToken] = []
            for try await result in transcriber.results {
                Self.append(result.text, to: &tokens)
                if duration > 0, let last = tokens.last {
                    onPhase(.transcribing(min(last.end / duration, 1)))
                }
            }
            return tokens
        }()

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            throw Failure.transcriptionFailed(error.localizedDescription)
        }

        let tokens = try await collected
        guard !tokens.isEmpty else { throw Failure.emptyResult }
        onPhase(.transcribing(1))
        return tokens
    }

    /// `AttributedString` → `TimedToken`。
    ///
    /// **不要自己拼词**：转写返回的文本本身已经带正确的空格与标点（模型产出的），
    /// 时间戳挂在 run 上。按顺序遍历累加即可，无需任何 index 换算，
    /// CJK/拉丁的接缝差异在这条路径上根本不出现（`TokenJoiner` 只在纯词表输入时才用）。
    static func append(_ text: AttributedString, to tokens: inout [TimedToken]) {
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            if let range = run.audioTimeRange {
                tokens.append(
                    TimedToken(
                        text: piece,
                        start: range.start.seconds,
                        end: range.end.seconds))
            } else if !tokens.isEmpty {
                // 没有时间戳的 run（多半是标点）并进上一个 token 的尾部，保证文本不丢
                tokens[tokens.count - 1].text += piece
            }
        }
    }
}
#endif
