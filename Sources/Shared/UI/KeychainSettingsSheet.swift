import SwiftUI

@MainActor
final class KeychainSettingsViewModel: ObservableObject {
    @Published var projectIDInput: String = ""
    @Published var apiKeyInput: String = ""
    @Published var maskedKeyStatus: String?
    @Published var selectedModel: GeminiModel
    @Published var autoAnalyzeMoxaPrimary: Bool
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
        self.maskedKeyStatus = keychain.maskedAPIKeyStatus()
    }

    func refreshState() {
        projectIDInput = keychain.loadProjectID()
        maskedKeyStatus = keychain.maskedAPIKeyStatus()
        selectedModel = keychain.loadPreferredModel()
        autoAnalyzeMoxaPrimary = ExtensionOpsConfig.isAutoAnalyzeMoxaPrimaryEnabled
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
            statusMessage = "✅ 零成本 countTokens 验证成功（\(model.displayName) · global，ping=\(tokens) token）"
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.tint)
                Text("Vertex AI Keychain 安全配置")
                    .font(.headline)
                Spacer()
                Button(onClose != nil ? "返回" : "关闭") {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }

            Text("调用所配置 GCP 项目的 `locations/\(GeminiModel.vertexLocation)` Google 1P Gemini 模型。API Key 仅保存在本机 macOS Keychain，绝不写入配置文件或 Git。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("输入 GCP Project ID（例如 your-gcp-project-id）", text: $vm.projectIDInput)
                            .textFieldStyle(.roundedBorder)
                        Button("保存 Project ID") {
                            vm.saveProjectID()
                            if !vm.isErrorStatus {
                                onSavedKey?()
                            }
                        }
                        .disabled(vm.projectIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack {
                        Text("当前 Keychain 状态：")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let status = vm.maskedKeyStatus {
                            Label(status, systemImage: "checkmark.shield.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                        } else {
                            Label("未配置 API Key", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }

                    SecureField("粘贴或更新 Vertex AI API Key", text: $vm.apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("保存到 Keychain") {
                            vm.saveKey()
                            if !vm.isErrorStatus {
                                onSavedKey?()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if vm.maskedKeyStatus != nil {
                            Button("清除 Key", role: .destructive) {
                                vm.deleteKey()
                            }
                        }

                        Spacer()
                    }
                }
                .padding(4)
            }

            GroupBox("默认模型 & 零成本连通性校验 (countTokens)") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("默认模型", selection: Binding(
                        get: { vm.selectedModel },
                        set: { vm.updatePreferredModel($0) }
                    )) {
                        ForEach(GeminiModel.allCases) { model in
                            Text("\(model.shortLabel) (\(model.rawValue))").tag(model)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        Button {
                            Task { await vm.testConnection(model: .flash38) }
                        } label: {
                            HStack(spacing: 4) {
                                if vm.isTestingConnection {
                                    ProgressView().controlSize(.small)
                                }
                                Text("测试 gemini-3.8-flash")
                            }
                        }
                        .disabled(vm.isTestingConnection)

                        Button {
                            Task { await vm.testConnection(model: .carbon4) }
                        } label: {
                            Text("测试 gemini-4-carbon")
                        }
                        .disabled(vm.isTestingConnection)

                        Spacer()
                    }

                    Divider()

                    Toggle(
                        "后台自动分析 Moxa Primary 新邮件（收信自动预热缓存）",
                        isOn: Binding(
                            get: { vm.autoAnalyzeMoxaPrimary },
                            set: { vm.updateAutoAnalyzeMoxaPrimary($0) }
                        )
                    )
                    .font(.caption)
                }
                .padding(4)
            }

            if let message = vm.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(vm.isErrorStatus ? .red : .green)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .onAppear {
            vm.refreshState()
        }
    }
}
