import SwiftUI

@MainActor
final class KeychainSettingsViewModel: ObservableObject {
    @Published var profiles: [AIProviderProfile] = []
    @Published var activeProfileID: String = AIProviderProfile.defaultVertexProfileID
    @Published var editingProfile: AIProviderProfile = AIProviderProfile.defaultVertexProfile()
    @Published var selectedTier: AIModelTier = .fast

    @Published var apiKeyInput: String = ""
    @Published var maskedKeyStatus: String?
    @Published var workspaceDisplayPath: String?

    @Published var autoAnalyzeMoxaPrimary: Bool
    @Published var autoFlagMoxaPrimary: Bool
    @Published var isTestingConnection = false
    @Published var statusMessage: String?
    @Published var isErrorStatus = false

    private let keychain: KeychainStore
    private let providerStore: AIProviderStore
    private let aiClient: AIServiceClient
    private let bookmarkStore: WorkspaceBookmarkStore

    init(
        keychain: KeychainStore = .shared,
        providerStore: AIProviderStore = .shared,
        aiClient: AIServiceClient = .shared,
        bookmarkStore: WorkspaceBookmarkStore = .shared
    ) {
        self.keychain = keychain
        self.providerStore = providerStore
        self.aiClient = aiClient
        self.bookmarkStore = bookmarkStore
        self.autoAnalyzeMoxaPrimary = ExtensionOpsConfig.isAutoAnalyzeMoxaPrimaryEnabled
        self.autoFlagMoxaPrimary = ExtensionOpsConfig.isAutoFlagMoxaPrimaryEnabled
        refreshState()
    }

    func refreshState() {
        profiles = providerStore.profiles
        let active = providerStore.activeProfile
        activeProfileID = active.id
        if let match = profiles.first(where: { $0.id == editingProfile.id }) {
            editingProfile = match
        } else {
            editingProfile = active
        }
        selectedTier = providerStore.preferredTier
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)
        workspaceDisplayPath = bookmarkStore.workspaceDisplayPath
        autoAnalyzeMoxaPrimary = ExtensionOpsConfig.isAutoAnalyzeMoxaPrimaryEnabled
        autoFlagMoxaPrimary = ExtensionOpsConfig.isAutoFlagMoxaPrimaryEnabled
    }

    func selectProfile(_ profile: AIProviderProfile) {
        providerStore.setActiveProfile(id: profile.id)
        activeProfileID = providerStore.activeProfileID
        editingProfile = providerStore.profile(forID: profile.id) ?? profile
        apiKeyInput = ""
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)
        statusMessage = nil
        isErrorStatus = false
    }

    func addPresetProfile(_ preset: AIProviderProfile) {
        let existingIDs = Set(providerStore.profiles.map(\.id))
        var newProfile = preset
        if existingIDs.contains(preset.id) {
            newProfile.id = UUID().uuidString
            let sameNameCount = providerStore.profiles.filter { $0.name.hasPrefix(preset.name) }.count
            if sameNameCount > 0 {
                newProfile.name = "\(preset.name) \(sameNameCount + 1)"
            }
        }
        providerStore.upsertProfile(newProfile, makeActive: true)
        profiles = providerStore.profiles
        activeProfileID = newProfile.id
        editingProfile = newProfile
        apiKeyInput = ""
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: newProfile.id)
        statusMessage = "已添加并启用「\(newProfile.name)」，请配置凭据后保存。"
        isErrorStatus = false
    }

    func addCustomProfile(kind: AIProviderKind) {
        let newProfile = AIProviderProfile(
            id: UUID().uuidString,
            name: "自定义 \(kind.displayName)",
            kind: kind
        )
        providerStore.upsertProfile(newProfile, makeActive: true)
        profiles = providerStore.profiles
        activeProfileID = newProfile.id
        editingProfile = newProfile
        apiKeyInput = ""
        maskedKeyStatus = nil
        statusMessage = "已创建自定义配置「\(newProfile.name)」。"
        isErrorStatus = false
    }

    func deleteEditingProfile() {
        guard profiles.count > 1 else {
            statusMessage = "至少需保留一个 AI 服务商配置。"
            isErrorStatus = true
            return
        }
        let targetID = editingProfile.id
        let targetName = editingProfile.name
        try? keychain.deleteAPIKey(forProfileID: targetID)
        providerStore.deleteProfile(id: targetID)
        profiles = providerStore.profiles
        let nextActive = providerStore.activeProfile
        activeProfileID = nextActive.id
        editingProfile = nextActive
        apiKeyInput = ""
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: nextActive.id)
        statusMessage = "已删除配置「\(targetName)」，当前切换为「\(nextActive.name)」。"
        isErrorStatus = false
    }

    func updateEditingKind(_ newKind: AIProviderKind) {
        let oldKind = editingProfile.kind
        guard oldKind != newKind else { return }
        editingProfile.kind = newKind
        if editingProfile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editingProfile.baseURL == oldKind.defaultBaseURL
        {
            editingProfile.baseURL = newKind.defaultBaseURL
        }
        if editingProfile.fastModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editingProfile.fastModel == oldKind.defaultFastModel
        {
            editingProfile.fastModel = newKind.defaultFastModel
        }
        if editingProfile.deepModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editingProfile.deepModel == oldKind.defaultDeepModel
        {
            editingProfile.deepModel = newKind.defaultDeepModel
        }
    }

    func saveProfileConfiguration() -> Bool {
        let trimmedName = editingProfile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfile.name = trimmedName.isEmpty ? editingProfile.kind.displayName : trimmedName

        let trimmedBase = editingProfile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfile.baseURL = trimmedBase.isEmpty ? editingProfile.kind.defaultBaseURL : trimmedBase

        editingProfile.projectID = editingProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = editingProfile.location.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfile.location = trimmedLocation.isEmpty ? "global" : trimmedLocation

        let trimmedFast = editingProfile.fastModel.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfile.fastModel = trimmedFast.isEmpty ? editingProfile.kind.defaultFastModel : trimmedFast

        let trimmedDeep = editingProfile.deepModel.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfile.deepModel = trimmedDeep.isEmpty ? editingProfile.kind.defaultDeepModel : trimmedDeep

        if editingProfile.kind.requiresProjectID, editingProfile.projectID.isEmpty {
            statusMessage = "Vertex AI 需要填写有效的 GCP Project ID。"
            isErrorStatus = true
            return false
        }

        providerStore.upsertProfile(editingProfile, makeActive: true)
        profiles = providerStore.profiles
        activeProfileID = editingProfile.id

        let candidateKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidateKey.isEmpty {
            do {
                try keychain.saveAPIKey(candidateKey, forProfileID: editingProfile.id)
                apiKeyInput = ""
                maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)
            } catch {
                statusMessage = error.localizedDescription
                isErrorStatus = true
                return false
            }
        }

        statusMessage = "已保存并启用「\(editingProfile.name)」。"
        isErrorStatus = false
        return true
    }

    func saveKey() -> Bool {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请先粘贴有效的 API Key。"
            isErrorStatus = true
            return false
        }

        do {
            try keychain.saveAPIKey(trimmed, forProfileID: editingProfile.id)
            apiKeyInput = ""
            maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)

            // Also persist any pending profile edits (e.g. Project ID / Base URL)
            if !editingProfile.kind.requiresProjectID
                || !editingProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                providerStore.upsertProfile(editingProfile, makeActive: true)
                profiles = providerStore.profiles
                activeProfileID = editingProfile.id
            }

            let account = KeychainStore.accountName(forProfileID: editingProfile.id)
            statusMessage = "已安全写入 macOS Keychain（\(account)）。"
            isErrorStatus = false
            return true
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
            return false
        }
    }

    func deleteKey() {
        do {
            try keychain.deleteAPIKey(forProfileID: editingProfile.id)
            maskedKeyStatus = nil
            statusMessage = "已从 macOS Keychain 删除「\(editingProfile.name)」的 API Key。"
            isErrorStatus = false
        } catch {
            statusMessage = error.localizedDescription
            isErrorStatus = true
        }
    }

    func updatePreferredTier(_ tier: AIModelTier) {
        selectedTier = tier
        providerStore.setPreferredTier(tier)
    }

    func chooseWorkspaceDirectory() {
        if let url = bookmarkStore.chooseWorkspaceDirectory() {
            workspaceDisplayPath = url.path
            statusMessage = "已授权附件归档工作区：\(url.path)"
            isErrorStatus = false
        }
    }

    func clearWorkspaceDirectory() {
        bookmarkStore.clearWorkspace()
        workspaceDisplayPath = nil
        statusMessage = "已清除附件归档工作区授权。"
        isErrorStatus = false
    }

    func updateAutoAnalyzeMoxaPrimary(_ enabled: Bool) {
        autoAnalyzeMoxaPrimary = enabled
        ExtensionOpsConfig.setAutoAnalyzeMoxaPrimaryEnabled(enabled)
    }

    func updateAutoFlagMoxaPrimary(_ enabled: Bool) {
        autoFlagMoxaPrimary = enabled
        ExtensionOpsConfig.setAutoFlagMoxaPrimaryEnabled(enabled)
    }

    func testConnection(tier: AIModelTier) async {
        let candidateKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = candidateKey.isEmpty
            ? keychain.loadAPIKey(forProfileID: editingProfile.id)
            : candidateKey

        guard let activeKey, !activeKey.isEmpty else {
            statusMessage = "未找到 API Key，请先输入或保存到 Keychain。"
            isErrorStatus = true
            return
        }

        if editingProfile.kind.requiresProjectID,
           editingProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            statusMessage = "请先填写 Vertex AI 的 GCP Project ID。"
            isErrorStatus = true
            return
        }

        isTestingConnection = true
        statusMessage = nil
        isErrorStatus = false
        defer { isTestingConnection = false }

        do {
            let resultMessage = try await aiClient.verifyConnection(
                profile: editingProfile,
                apiKey: activeKey,
                tier: tier
            )
            statusMessage = "✅ \(resultMessage)"
            isErrorStatus = false
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
            isErrorStatus = true
        }
    }

    var editingProfileHasCompleteCredentials: Bool {
        let hasKey = keychain.hasAPIKey(forProfileID: editingProfile.id)
        if editingProfile.kind.requiresProjectID {
            return hasKey && !editingProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasKey
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
                Text("AI 服务商、工作区与扩展设置")
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
                    providerManagementSection
                    credentialsSection
                    modelTierAndTestSection
                    workspaceBookmarkSection
                    automationSection

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
        .frame(minWidth: 480, minHeight: 500)
        .background(MailVibrancyBackground())
        .onAppear {
            vm.refreshState()
        }
    }

    private var providerManagementSection: some View {
        MailSectionContainer(
            title: "AI 服务商配置",
            systemImage: "server.rack",
            trailing: {
                HStack(spacing: 6) {
                    Menu {
                        Section("内置预设") {
                            ForEach(AIProviderProfile.builtInPresets) { preset in
                                Button(preset.name) {
                                    vm.addPresetProfile(preset)
                                }
                            }
                        }
                        Divider()
                        Section("自定义配置") {
                            ForEach(AIProviderKind.allCases) { kind in
                                Button("新建 \(kind.displayName)") {
                                    vm.addCustomProfile(kind: kind)
                                }
                            }
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    if vm.profiles.count > 1 {
                        Button(role: .destructive) {
                            vm.deleteEditingProfile()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("删除当前选中的服务商配置")
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("当前启用")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    Picker("当前服务商", selection: Binding(
                        get: { vm.activeProfileID },
                        set: { id in
                            if let profile = vm.profiles.first(where: { $0.id == id }) {
                                vm.selectProfile(profile)
                            }
                        }
                    )) {
                        ForEach(vm.profiles) { profile in
                            Text("\(profile.name) · \(profile.kind.displayName)").tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                Divider().opacity(0.45)

                fieldRow(label: "配置名称") {
                    TextField("例如：OpenAI / DeepSeek / Vertex AI", text: $vm.editingProfile.name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                fieldRow(label: "接口类型") {
                    Picker("接口类型", selection: Binding(
                        get: { vm.editingProfile.kind },
                        set: { vm.updateEditingKind($0) }
                    )) {
                        ForEach(AIProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                fieldRow(label: "Base URL") {
                    TextField(vm.editingProfile.kind.defaultBaseURL, text: $vm.editingProfile.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5, design: .monospaced))
                }

                if vm.editingProfile.kind.requiresProjectID {
                    fieldRow(label: "Project ID") {
                        TextField("GCP Project ID", text: $vm.editingProfile.projectID)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }

                if vm.editingProfile.kind.supportsLocation {
                    fieldRow(label: "区域") {
                        TextField("global", text: $vm.editingProfile.location)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }

                fieldRow(label: "极速模型") {
                    TextField(vm.editingProfile.kind.defaultFastModel, text: $vm.editingProfile.fastModel)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5, design: .monospaced))
                }

                fieldRow(label: "深度模型") {
                    TextField(vm.editingProfile.kind.defaultDeepModel, text: $vm.editingProfile.deepModel)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5, design: .monospaced))
                }

                HStack {
                    Spacer()
                    Button("保存配置") {
                        if vm.saveProfileConfiguration(), vm.editingProfileHasCompleteCredentials {
                            onSavedKey?()
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var credentialsSection: some View {
        MailSectionContainer(title: "API Key 凭据（\(vm.editingProfile.name)）", systemImage: "key") {
            VStack(alignment: .leading, spacing: 8) {
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

                SecureField("粘贴或更新「\(vm.editingProfile.name)」API Key", text: $vm.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                HStack(spacing: 8) {
                    Button("保存到 Keychain") {
                        if vm.saveKey(), vm.editingProfileHasCompleteCredentials {
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
    }

    private var modelTierAndTestSection: some View {
        MailSectionContainer(title: "默认模型档位与连通性校验", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("默认档位", selection: Binding(
                    get: { vm.selectedTier },
                    set: { vm.updatePreferredTier($0) }
                )) {
                    ForEach(AIModelTier.allCases) { tier in
                        Text("\(tier.displayName) (\(vm.editingProfile.modelName(for: tier)))").tag(tier)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                HStack(spacing: 8) {
                    Button {
                        Task { await vm.testConnection(tier: .fast) }
                    } label: {
                        HStack(spacing: 4) {
                            if vm.isTestingConnection {
                                ProgressView().controlSize(.small)
                            }
                            Text("测试连通性（极速）")
                        }
                    }
                    .controlSize(.small)
                    .disabled(vm.isTestingConnection)

                    Button("测试深度模型") {
                        Task { await vm.testConnection(tier: .deep) }
                    }
                    .controlSize(.small)
                    .disabled(vm.isTestingConnection)

                    Spacer()
                }
            }
        }
    }

    private var workspaceBookmarkSection: some View {
        MailSectionContainer(title: "Moxa 附件归档工作区（安全书签）", systemImage: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 7) {
                if let path = vm.workspaceDisplayPath {
                    Text(path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    Text("尚未选择工作区根目录（推荐 ~/Documents/Moxa）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("选择 / 更换归档目录…") {
                        vm.chooseWorkspaceDirectory()
                    }
                    .controlSize(.small)

                    if vm.workspaceDisplayPath != nil {
                        Button("清除授权", role: .destructive) {
                            vm.clearWorkspaceDirectory()
                        }
                        .controlSize(.small)
                    }

                    Spacer()
                }
            }
        }
    }

    private var automationSection: some View {
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
    }

    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            content()
        }
    }
}
