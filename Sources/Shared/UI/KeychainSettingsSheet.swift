import SwiftUI

@MainActor
final class KeychainSettingsViewModel: ObservableObject {
    @Published var projectIDInput: String = ""
    @Published var apiKeyInput: String = ""
    @Published var maskedKeyStatus: String?
    @Published var selectedModel: GeminiModel
    @Published var autoAnalyzeMoxaPrimary: Bool
    @Published var autoFlagMoxaPrimary: Bool
    @Published var isTestingConnection = false
    @Published var statusMessage: String?
    @Published var isErrorStatus = false

    private let keychain: KeychainStore
    private let client: VertexGeminiClient

    init(keychain: KeychainStore = .shared, client: VertexGeminiClient = .shared) {
        self.keychain = keychain
        self.client = client
        self.projectIDInput = keychain.loadProjectID()
        self.selectedModel = keychain.loadPreferredModel()
        self.autoAnalyzeMoxaPrimary = ExtensionOpsConfig.isAutoAnalyzeMoxaPrimaryEnabled
        self.autoFlagMoxaPrimary = ExtensionOpsConfig.isAutoFlagMoxaPrimaryEnabled
        self.maskedKeyStatus = keychain.maskedAPIKeyStatus()
    }

    func refreshState() {
        projectIDInput = keychain.loadProjectID()
        maskedKeyStatus = keychain.maskedAPIKeyStatus()
        selectedModel = keychain.loadPreferredModel()
        autoAnalyzeMoxaPrimary = ExtensionOpsConfig.isAutoAnalyzeMoxaPrimaryEnabled
        autoFlagMoxaPrimary = ExtensionOpsConfig.isAutoFlagMoxaPrimaryEnabled
    }

    func saveProjectID() {
        let trimmed = projectIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请先填写有效的 GCP Project ID。"
            isErrorStatus = true
            return
        }
        keychain.saveProjectID(trimmed)
        projectIDInput = trimmed
        statusMessage = "已保存 GCP Project ID（\(trimmed)）。"
        isErrorStatus = false
    }

    func saveKey() {
        let trimmedProject = projectIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty {
            keychain.saveProjectID(trimmedProject)
        }
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请先粘贴有效的 Vertex AI API Key。"
            isErrorStatus = true
            return
        }
        do {
            try keychain.saveAPIKey(trimmed)
            apiKeyInput = ""
            maskedKeyStatus = keychain.maskedAPIKeyStatus()
            statusMessage = "已安全写入 macOS Keychain（\(KeychainStore.apiKeyAccount)）。"
            isErrorStatus = false
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }

    func deleteKey() {
        do {
            try keychain.deleteAPIKey()
            maskedKeyStatus = nil
            statusMessage = "已从 macOS Keychain 删除 API Key。"
            isErrorStatus = false
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }

    func updatePreferredModel(_ model: GeminiModel) {
        selectedModel = model
        keychain.savePreferredModel(model)
    }

    func updateAutoAnalyzeMoxaPrimary(_ enabled: Bool) {
        autoAnalyzeMoxaPrimary = enabled
        ExtensionOpsConfig.setAutoAnalyzeMoxaPrimaryEnabled(enabled)
    }

    func updateAutoFlagMoxaPrimary(_ enabled: Bool) {
        autoFlagMoxaPrimary = enabled
        ExtensionOpsConfig.setAutoFlagMoxaPrimaryEnabled(enabled)
    }

    func testConnection(model: GeminiModel) async {
        let candidateKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = candidateKey.isEmpty ? keychain.loadAPIKey() : candidateKey
        guard let activeKey, !activeKey.isEmpty else {
            statusMessage = "未找到 API Key，请先输入或保存到 Keychain。"
            isErrorStatus = true
            return
        }

        let candidateProject = projectIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeProject = candidateProject.isEmpty ? keychain.loadProjectID() : candidateProject
        guard !activeProject.isEmpty else {
            statusMessage = "未填写 GCP Project ID，请先输入或保存。"
            isErrorStatus = true
            return
        }

        isTestingConnection = true
        statusMessage = nil
        isErrorStatus = false
        defer { isTestingConnection = false }

        do {
            let tokens = try await client.verifyAPIKeyAndModel(
                apiKey: activeKey,
                model: model,
                projectID: activeProject
            )
            statusMessage = "验证通过：\(model.displayName) · global（ping = \(tokens) token）"
            isErrorStatus = false
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }
}

public struct KeychainSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = KeychainSettingsViewModel()

    public var onSavedKey: (() -> Void)?
    public var onClose: (() -> Void)?

    public init(onSavedKey: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.onSavedKey = onSavedKey
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("扩展设置与凭据")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button(onClose != nil ? "完成" : "关闭") {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    MailSectionContainer(title: "Vertex AI 凭据（locations/\(GeminiModel.vertexLocation)）", systemImage: "key") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("GCP Project ID", text: $vm.projectIDInput)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                Button("保存 ID") {
                                    vm.saveProjectID()
                                    if !vm.isErrorStatus {
                                        onSavedKey?()
                                    }
                                }
                                .controlSize(.small)
                                .disabled(vm.projectIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            HStack(spacing: 6) {
                                Text("Keychain 状态：")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                if let status = vm.maskedKeyStatus {
                                    Label(status, systemImage: "checkmark.shield.fill")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.green)
                                } else {
                                    Label("未配置 API Key", systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.orange)
                                }
                            }

                            SecureField("粘贴或更新 Vertex AI API Key", text: $vm.apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)

                            HStack(spacing: 8) {
                                Button("保存到 Keychain") {
                                    vm.saveKey()
                                    if !vm.isErrorStatus {
                                        onSavedKey?()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(vm.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                if vm.maskedKeyStatus != nil {
                                    Button("清除 Key", role: .destructive) {
                                        vm.deleteKey()
                                    }
                                    .controlSize(.small)
                                }

                                Spacer()
                            }
                        }
                    }

                    MailSectionContainer(title: "默认模型与连通性校验", systemImage: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("默认模型", selection: Binding(
                                get: { vm.selectedModel },
                                set: { vm.updatePreferredModel($0) }
                            )) {
                                ForEach(GeminiModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)

                            HStack(spacing: 8) {
                                Button {
                                    Task { await vm.testConnection(model: .flash38) }
                                } label: {
                                    HStack(spacing: 4) {
                                        if vm.isTestingConnection {
                                            ProgressView().controlSize(.small)
                                        }
                                        Text("测试 Flash 3.8")
                                    }
                                }
                                .controlSize(.small)
                                .disabled(vm.isTestingConnection)

                                Button("测试 Carbon 4") {
                                    Task { await vm.testConnection(model: .carbon4) }
                                }
                                .controlSize(.small)
                                .disabled(vm.isTestingConnection)

                                Spacer()
                            }
                        }
                    }

                    MailSectionContainer(title: "自动化与系统集成", systemImage: "wand.and.stars") {
                        VStack(alignment: .leading, spacing: 7) {
                            Toggle(
                                "后台自动分析 Moxa Primary 新邮件",
                                isOn: Binding(
                                    get: { vm.autoAnalyzeMoxaPrimary },
                                    set: { vm.updateAutoAnalyzeMoxaPrimary($0) }
                                )
                            )
                            .font(.system(size: 12))

                            Toggle(
                                "后台自动标记 7 色邮件旗标（紧急待回 / 跟报价 / 技术卡点等）",
                                isOn: Binding(
                                    get: { vm.autoFlagMoxaPrimary },
                                    set: { vm.updateAutoFlagMoxaPrimary($0) }
                                )
                            )
                            .font(.system(size: 12))
                            .disabled(!vm.autoAnalyzeMoxaPrimary)
                        }
                    }

                    if let message = vm.statusMessage {
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(vm.isErrorStatus ? .red : .green)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(MailVibrancyBackground())
        .onAppear {
            vm.refreshState()
        }
    }
}
