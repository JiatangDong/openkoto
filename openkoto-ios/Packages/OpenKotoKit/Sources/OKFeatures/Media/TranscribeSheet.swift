#if os(iOS)
import OKDesignSystem
import OKLocalization
import OKMedia
import OKModels
import SwiftUI

/// 端上生成字幕。
///
/// 两段式进度：抽音轨 → （首次用某语言时）下模型 → 转写。
/// 三段耗时差异很大，合成一个百分比会让用户以为卡住了，所以分开报。
@available(iOS 26, *)
struct TranscribeSheet: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let media: Media

    @State private var locales: [Locale] = []
    @State private var selected: Locale?
    @State private var phase: SpeechTranscriberService.Phase?
    @State private var task: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var finishedCount: Int?

    private var isRunning: Bool { task != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let finishedCount {
                    Section {
                        Label(
                            L("media.transcribe.done\(finishedCount)"),
                            systemImage: "checkmark.circle")
                            .foregroundStyle(theme.explained)
                    }
                } else if isRunning {
                    progressSection
                } else {
                    localeSection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(theme.destructive)
                    }
                }
            }
            .navigationTitle(L("media.transcribe.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRunning ? L("common.cancel") : L("common.close")) {
                        if isRunning {
                            task?.cancel()
                            task = nil
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if finishedCount != nil {
                        Button(L("common.done")) { dismiss() }
                    } else {
                        Button(L("media.transcribe.start")) { start() }
                            .disabled(selected == nil || isRunning)
                    }
                }
            }
            .task { await loadLocales() }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var localeSection: some View {
        Section {
            Picker(L("media.transcribe.language"), selection: $selected) {
                ForEach(locales, id: \.identifier) { locale in
                    Text(Self.displayName(locale)).tag(Optional(locale))
                }
            }
            .pickerStyle(.navigationLink)
        } footer: {
            Text(L("media.transcribe.footer"))
        }
    }

    private var progressSection: some View {
        Section {
            switch phase {
            case .preparingAudio, .none:
                ProgressView(L("media.transcribe.preparing"))
            case .downloadingModel(let value):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("media.transcribe.downloadingModel"))
                        .font(.subheadline)
                    ProgressView(value: value)
                }
            case .transcribing(let value):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("media.transcribe.running"))
                        .font(.subheadline)
                    ProgressView(value: value)
                }
            }
        } footer: {
            // 没开后台音频，切后台会被系统掐掉——如实说明，不假装还在跑。
            Text(L("media.transcribe.keepOpen"))
        }
    }

    private func loadLocales() async {
        let supported = await SpeechTranscriberService.supportedLocales()
        locales = supported.sorted { Self.displayName($0) < Self.displayName($1) }
        guard selected == nil else { return }
        // 优先用媒体自带的语种提示，否则跟随当前系统语言
        let preferred = media.language ?? Locale.current.identifier(.bcp47)
        selected =
            locales.first { $0.identifier(.bcp47).lowercased() == preferred.lowercased() }
            ?? locales.first {
                $0.language.languageCode?.identifier
                    == Locale(identifier: preferred).language.languageCode?.identifier
            }
            ?? locales.first
    }

    private func start() {
        guard let selected else { return }
        errorMessage = nil
        task = Task {
            do {
                let count = try await store.transcribe(
                    mediaID: media.id, locale: selected,
                    onPhase: { newPhase in
                        Task { @MainActor in phase = newPhase }
                    })
                finishedCount = count
            } catch is CancellationError {
                // 用户主动取消，不当错误报
            } catch {
                errorMessage = error.localizedDescription
            }
            task = nil
            phase = nil
        }
    }

    static func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier(.bcp47))
            ?? locale.identifier(.bcp47)
    }
}
#endif
