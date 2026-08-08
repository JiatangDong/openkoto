#if os(iOS)
import SwiftUI
import OKModels
import OKAIClient
import OKDesignSystem
import OKLocalization

/// 模型配置表单（新增/编辑），设计文档 §6.6。
/// 表单字段：名称 / Provider / 模型名 / API Key(SecureField→Keychain) / 自定义 Base URL；
/// “测试连接”发一条最小 chat 请求。Provider 能力表驱动字段可见性与校验。
struct ModelConfigFormView: View {
    @Environment(AppConfigStore.self) private var appConfig
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// nil = 新增；非 nil = 编辑该配置。
    let editing: ModelConfig?

    @State private var name: String
    @State private var provider: ProviderID
    @State private var model: String
    @State private var baseURLString: String
    @State private var apiKeyInput: String = ""
    @State private var makeDefault: Bool

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, success, failure(String)
    }

    init(editing: ModelConfig?) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _provider = State(initialValue: editing?.apiProvider ?? .openai)
        _model = State(initialValue: editing?.model ?? "")
        _baseURLString = State(initialValue: editing?.baseURL?.absoluteString ?? "")
        _makeDefault = State(initialValue: editing?.isDefault ?? true)
    }

    private var capability: ProviderCapability {
        ProviderCapability.capability(for: provider)
    }

    private var hasStoredKey: Bool {
        guard let editing else { return false }
        return appConfig.hasKey(for: editing.id)
    }

    /// 自定义 Base URL 用 http 且非本地 Provider → 明文告警（设计文档 §4.5）。
    private var insecureBaseURL: Bool {
        baseURLString.lowercased().hasPrefix("http://") && !capability.isLocalProvider
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (!capability.requiresCustomBaseURL || !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("model.form.name"), text: $name)
                        .textInputAutocapitalization(.never)
                    Picker(L("model.form.provider"), selection: $provider) {
                        ForEach(ProviderCapability.all, id: \.id) { cap in
                            Text(cap.displayName).tag(cap.id)
                        }
                    }
                    TextField(L("model.form.model"), text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    SecureField(
                        hasStoredKey ? L("model.form.apiKey.configured") : L("model.form.apiKey"),
                        text: $apiKeyInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } footer: {
                    if capability.allowsEmptyKey {
                        Text(L("model.form.apiKey.localOptional"))
                    }
                }

                if capability.requiresCustomBaseURL || !baseURLString.isEmpty {
                    Section {
                        TextField(L("model.form.baseURL"), text: $baseURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if capability.requiresCustomBaseURL {
                                Text(L("model.form.baseURL.required"))
                            }
                            if insecureBaseURL {
                                Label(L("model.form.http.warning"), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(theme.destructive)
                            }
                        }
                    }
                }

                Section {
                    Toggle(L("model.form.default"), isOn: $makeDefault)
                }

                Section {
                    testRow
                }

                if let policy = capability.privacyPolicyURL {
                    Section {
                        Link(destination: policy) {
                            Label(L("model.form.privacy"), systemImage: "hand.raised")
                        }
                    } footer: {
                        Text(L("model.form.privacy.note"))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(editing == nil ? L("settings.models.add") : L("settings.models.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("model.form.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("model.form.save")) { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - 测试连接

    @ViewBuilder
    private var testRow: some View {
        Button {
            Task { await test() }
        } label: {
            HStack {
                Label(L("model.form.test"), systemImage: "bolt.horizontal")
                Spacer()
                switch testState {
                case .idle: EmptyView()
                case .testing: ProgressView()
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.destructive)
                }
            }
        }
        .disabled(!canSave || testState == .testing)

        if case let .failure(message) = testState {
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.destructive)
        } else if testState == .success {
            Text(L("model.form.test.success"))
                .font(.footnote)
                .foregroundStyle(.green)
        }
    }

    private func draftConfig() -> ModelConfig {
        ModelConfig(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            apiProvider: provider,
            model: model.trimmingCharacters(in: .whitespaces),
            baseURL: baseURLString.isEmpty ? nil : URL(string: baseURLString.trimmingCharacters(in: .whitespaces)),
            isDefault: makeDefault
        )
    }

    /// 测试用 Key：优先本次输入，否则用已存 Key（编辑态）。
    private func effectiveKey() -> String? {
        if !apiKeyInput.isEmpty { return apiKeyInput }
        if let editing { return appConfig.apiKey(for: editing.id) }
        return nil
    }

    private func test() async {
        testState = .testing
        do {
            try await appConfig.testConnection(draftConfig(), apiKey: effectiveKey())
            testState = .success
        } catch let failure as AIRequestFailure {
            testState = .failure(userMessage(for: failure.error))
        } catch let error as AIClientError {
            testState = .failure(userMessage(for: error))
        } catch {
            testState = .failure(userMessage(for: .malformedResponse(requestID: UUID())))
        }
    }

    private func save() {
        appConfig.addOrUpdate(draftConfig(), apiKey: apiKeyInput.isEmpty ? nil : apiKeyInput)
        dismiss()
    }
}
#endif
