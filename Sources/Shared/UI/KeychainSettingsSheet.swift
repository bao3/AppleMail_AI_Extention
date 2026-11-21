import SwiftUI

@MainActor
final class KeychainSettingsViewModel: ObservableObject {
    enum ConnectionTestResult: Equatable {
        case available(tier: AIModelTier, detail: String)
        case unavailable(tier: AIModelTier, detail: String)
    }

    @Published var profiles: [AIProviderProfile] = []
    @Published var activeProfileID: String = AIProviderProfile.defaultVertexProfileID
    @Published var editingProfile: AIProviderProfile = AIProviderProfile.defaultVertexProfile()
    @Published var selectedTier: AIModelTier = .fast

    @Published var apiKeyInput: String = ""
    @Published var maskedKeyStatus: String?
    @Published var workspaceDisplayPath: String?

    @Published var autoAnalyzePrimary: Bool
    @Published var autoFlagPrimary: Bool
    @Published var filterAllowedDomainsInput: String
    @Published var filterSelfAddressesInput: String
    @Published var testingTier: AIModelTier?
    @Published var isFetchingModels = false
    @Published var fetchedModels: [String] = []
    @Published var connectionTestResult: ConnectionTestResult?
    @Published var statusMessage: String?
    @Published var isErrorStatus = false

    var isTestingConnection: Bool {
        testingTier != nil
    }

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

        let active = providerStore.activeProfile
        self.profiles = providerStore.profiles
        self.activeProfileID = active.id
        self.editingProfile = active
        self.selectedTier = providerStore.preferredTier
        self.maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: active.id)
        self.workspaceDisplayPath = bookmarkStore.workspaceDisplayPath
        self.autoAnalyzePrimary = ExtensionOpsConfig.isAutoAnalyzePrimaryEnabled
        self.autoFlagPrimary = ExtensionOpsConfig.isAutoFlagPrimaryEnabled
        let initialScope = PrimaryMailFilter.loadScope()
        self.filterAllowedDomainsInput = initialScope.allowedDomains.joined(separator: ", ")
        self.filterSelfAddressesInput = initialScope.selfAddresses.joined(separator: ", ")
    }

    func refreshState() {
        providerStore.reload()
        profiles = providerStore.profiles
        let active = providerStore.activeProfile
        if activeProfileID != active.id || !profiles.contains(where: { $0.id == editingProfile.id }) {
            activeProfileID = active.id
            editingProfile = active
            apiKeyInput = ""
            fetchedModels = []
            connectionTestResult = nil
        }
        selectedTier = providerStore.preferredTier
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)
        workspaceDisplayPath = bookmarkStore.workspaceDisplayPath
        autoAnalyzePrimary = ExtensionOpsConfig.isAutoAnalyzePrimaryEnabled
        autoFlagPrimary = ExtensionOpsConfig.isAutoFlagPrimaryEnabled
        let scope = PrimaryMailFilter.loadScope()
        filterAllowedDomainsInput = scope.allowedDomains.joined(separator: ", ")
        filterSelfAddressesInput = scope.selfAddresses.joined(separator: ", ")
    }

    func selectProfile(_ profile: AIProviderProfile) {
        providerStore.setActiveProfile(id: profile.id)
        activeProfileID = providerStore.activeProfileID
        editingProfile = providerStore.profile(forID: profile.id) ?? profile
        apiKeyInput = ""
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)
        fetchedModels = []
        connectionTestResult = nil
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
        fetchedModels = []
        connectionTestResult = nil
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
        fetchedModels = []
        connectionTestResult = nil
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
        fetchedModels = []
        connectionTestResult = nil
        statusMessage = "已删除配置「\(targetName)」，当前切换为「\(nextActive.name)」。"
        isErrorStatus = false
    }

    func updateEditingKind(_ newKind: AIProviderKind) {
        let oldKind = editingProfile.kind
        guard oldKind != newKind else { return }
        editingProfile.kind = newKind
        fetchedModels = []
        connectionTestResult = nil
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
        providerStore.setPreferredTier(selectedTier)
        savePrimaryFilterScope()
        profiles = providerStore.profiles
        activeProfileID = editingProfile.id

        let candidateKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var didSaveKey = false
        if !candidateKey.isEmpty {
            do {
                try keychain.saveAPIKey(candidateKey, forProfileID: editingProfile.id)
                apiKeyInput = ""
                maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: editingProfile.id)
                didSaveKey = true
            } catch {
                statusMessage = error.localizedDescription
                isErrorStatus = true
                return false
            }
        }

        statusMessage = didSaveKey
            ? "已保存并启用「\(editingProfile.name)」（API Key 已写入 Keychain）。"
            : "已保存并启用「\(editingProfile.name)」。"
        isErrorStatus = false
        return true
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

    func updateAutoAnalyzePrimary(_ enabled: Bool) {
        autoAnalyzePrimary = enabled
        ExtensionOpsConfig.setAutoAnalyzePrimaryEnabled(enabled)
    }

    func updateAutoFlagPrimary(_ enabled: Bool) {
        autoFlagPrimary = enabled
        ExtensionOpsConfig.setAutoFlagPrimaryEnabled(enabled)
    }

    func savePrimaryFilterScope() {
        var scope = PrimaryMailFilter.loadScope()
        scope = PrimaryMailFilterScope(
            allowedDomains: PrimaryMailFilterScope.parseCommaSeparated(filterAllowedDomainsInput, stripLeadingAt: true),
            allowedTenantIDs: scope.allowedTenantIDs,
            selfAddresses: PrimaryMailFilterScope.parseCommaSeparated(filterSelfAddressesInput),
            customBotAddresses: scope.customBotAddresses
        )
        PrimaryMailFilter.saveScope(scope)
        filterAllowedDomainsInput = scope.allowedDomains.joined(separator: ", ")
        filterSelfAddressesInput = scope.selfAddresses.joined(separator: ", ")
    }

    var fallbackModelSuggestions: [String] {
        var candidates: [String] = [
            editingProfile.fastModel,
            editingProfile.deepModel,
            editingProfile.kind.defaultFastModel,
            editingProfile.kind.defaultDeepModel
        ]
        switch editingProfile.kind {
        case .vertexAI, .geminiDeveloper:
            candidates.append(contentsOf: GeminiModel.allCases.map(\.rawValue))
            candidates.append(contentsOf: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.8-flash", "gemini-4-carbon", "gemini-4-hydrogen"])
        case .openAICompatible:
            candidates.append(contentsOf: AIProviderProfile.builtInPresets
                .filter { $0.kind == .openAICompatible }
                .flatMap { [$0.fastModel, $0.deepModel] })
        case .anthropic:
            candidates.append(contentsOf: ["claude-3-5-haiku-latest", "claude-sonnet-4-20250514", "claude-3-7-sonnet-latest"])
        }
        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func fetchModels() async {
        let activeKey: String
        switch resolveCredentials(missingKeyMessage: "未找到 API Key，请先输入或保存 API Key 后再获取模型。") {
        case let .success(key):
            activeKey = key
        case let .failure(message):
            statusMessage = message
            isErrorStatus = true
            return
        }

        isFetchingModels = true
        statusMessage = nil
        isErrorStatus = false
        defer { isFetchingModels = false }

        do {
            let models = try await aiClient.fetchAvailableModels(
                profile: editingProfile,
                apiKey: activeKey
            )
            fetchedModels = models
            statusMessage = "已获取 \(models.count) 个可用模型，可在下拉框中选择。"
            isErrorStatus = false
        } catch {
            statusMessage = "❌ 获取模型失败：\(error.localizedDescription)"
            isErrorStatus = true
        }
    }

    func testConnection(tier: AIModelTier) async {
        let activeKey: String
        switch resolveCredentials(missingKeyMessage: "未找到 API Key，请先输入 API Key 并点击「保存配置」。") {
        case let .success(key):
            activeKey = key
        case let .failure(message):
            connectionTestResult = .unavailable(tier: tier, detail: message)
            statusMessage = message
            isErrorStatus = true
            return
        }

        testingTier = tier
        connectionTestResult = nil
        statusMessage = nil
        isErrorStatus = false
        defer { testingTier = nil }

        do {
            let resultMessage = try await aiClient.verifyConnection(
                profile: editingProfile,
                apiKey: activeKey,
                tier: tier
            )
            connectionTestResult = .available(tier: tier, detail: resultMessage)
            statusMessage = "✅ \(resultMessage)"
            isErrorStatus = false
        } catch {
            connectionTestResult = .unavailable(tier: tier, detail: error.localizedDescription)
            statusMessage = "❌ \(error.localizedDescription)"
            isErrorStatus = true
        }
    }

    private enum CredentialResolution {
        case success(String)
        case failure(String)
    }

    private func resolveCredentials(missingKeyMessage: String) -> CredentialResolution {
        let candidateKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = candidateKey.isEmpty
            ? keychain.loadAPIKey(forProfileID: editingProfile.id)
            : candidateKey

        guard let activeKey, !activeKey.isEmpty else {
            return .failure(missingKeyMessage)
        }
        if editingProfile.kind.requiresProjectID,
           editingProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .failure("请先填写 Vertex AI 的 GCP Project ID。")
        }
        return .success(activeKey)
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

    private let actionColumnWidth: CGFloat = 84

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

                    let selectedProfile = vm.profiles.first(where: { $0.id == vm.activeProfileID }) ?? vm.editingProfile
                    Menu {
                        ForEach(vm.profiles) { profile in
                            Button {
                                vm.selectProfile(profile)
                            } label: {
                                HStack {
                                    Text("\(profile.name) · \(profile.kind.displayName)")
                                    if profile.id == vm.activeProfileID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(selectedProfile.name) · \(selectedProfile.kind.displayName)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.75)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Spacer(minLength: 0)
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
                    .fixedSize()
                    Spacer(minLength: 0)
                }

                fieldRow(label: "Base URL") {
                    HStack(spacing: 6) {
                        TextField(vm.editingProfile.kind.defaultBaseURL, text: $vm.editingProfile.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11.5, design: .monospaced))

                        Button {
                            Task { await vm.fetchModels() }
                        } label: {
                            HStack(spacing: 4) {
                                if vm.isFetchingModels {
                                    ProgressView().controlSize(.small)
                                }
                                Text(vm.isFetchingModels ? "获取中" : "获取模型")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .frame(width: actionColumnWidth)
                        .disabled(vm.isFetchingModels)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Text("API Key")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            SecureField(
                                vm.maskedKeyStatus ?? "粘贴或更新「\(vm.editingProfile.name)」API Key",
                                text: $vm.apiKeyInput
                            )
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                            if vm.maskedKeyStatus != nil {
                                Button("清除 Key", role: .destructive) {
                                    vm.deleteKey()
                                }
                                .controlSize(.small)
                                .frame(width: actionColumnWidth)
                            } else {
                                Text("未配置")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                    .frame(width: actionColumnWidth, alignment: .center)
                            }
                        }

                        if let status = vm.maskedKeyStatus {
                            Label(status, systemImage: "checkmark.shield.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                        }
                    }
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
                    HStack(spacing: 6) {
                        modelComboField(
                            placeholder: vm.editingProfile.kind.defaultFastModel,
                            text: $vm.editingProfile.fastModel
                        )
                        defaultTierButton(for: .fast)
                    }
                }

                fieldRow(label: "深度模型") {
                    HStack(spacing: 6) {
                        modelComboField(
                            placeholder: vm.editingProfile.kind.defaultDeepModel,
                            text: $vm.editingProfile.deepModel
                        )
                        defaultTierButton(for: .deep)
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        Task { await vm.testConnection(tier: .fast) }
                    } label: {
                        HStack(spacing: 4) {
                            if vm.testingTier == .fast {
                                ProgressView().controlSize(.small)
                            }
                            Text("测试极速")
                        }
                    }
                    .controlSize(.small)
                    .disabled(vm.isTestingConnection)

                    Button {
                        Task { await vm.testConnection(tier: .deep) }
                    } label: {
                        HStack(spacing: 4) {
                            if vm.testingTier == .deep {
                                ProgressView().controlSize(.small)
                            }
                            Text("测试深度")
                        }
                    }
                    .controlSize(.small)
                    .disabled(vm.isTestingConnection)

                    if let testResult = vm.connectionTestResult {
                        switch testResult {
                        case let .available(tier, detail):
                            Label("\(tier.displayName)可用", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .help(detail)
                        case let .unavailable(tier, detail):
                            Label("\(tier.displayName)不可用", systemImage: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .help(detail)
                        }
                    }

                    Spacer(minLength: 4)

                    Button("保存配置") {
                        if vm.saveProfileConfiguration(), vm.editingProfileHasCompleteCredentials {
                            onSavedKey?()
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
    }

    private func modelComboField(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.leading, 7)
                .padding(.vertical, 4)

            Menu {
                if !vm.fetchedModels.isEmpty {
                    ForEach(vm.fetchedModels, id: \.self) { modelID in
                        Button {
                            text.wrappedValue = modelID
                        } label: {
                            HStack {
                                Text(modelID)
                                if text.wrappedValue == modelID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } else {
                    Text("点击「获取模型」拉取在线列表")
                    Divider()
                    ForEach(vm.fallbackModelSuggestions, id: \.self) { modelID in
                        Button {
                            text.wrappedValue = modelID
                        } label: {
                            HStack {
                                Text(modelID)
                                if text.wrappedValue == modelID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private func defaultTierButton(for tier: AIModelTier) -> some View {
        if vm.selectedTier == tier {
            Label("已默认", systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: actionColumnWidth, height: 22)
                .background(Color.green.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.green.opacity(0.35), lineWidth: 0.75)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Button("设为默认") {
                vm.updatePreferredTier(tier)
            }
            .controlSize(.small)
            .frame(width: actionColumnWidth)
        }
    }

    private var workspaceBookmarkSection: some View {
        MailSectionContainer(title: "附件智能归档工作区（安全书签）", systemImage: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 7) {
                if let path = vm.workspaceDisplayPath {
                    Text(path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    Text("尚未选择工作区根目录（例如 ~/Documents/Archive）")
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
                    "后台自动分析重点收件新邮件（Primary）",
                    isOn: Binding(
                        get: { vm.autoAnalyzePrimary },
                        set: { vm.updateAutoAnalyzePrimary($0) }
                    )
                )
                .font(.system(size: 12))

                Toggle(
                    "后台自动标记 7 色邮件旗标（紧急待回 / 跟报价 / 技术卡点等）",
                    isOn: Binding(
                        get: { vm.autoFlagPrimary },
                        set: { vm.updateAutoFlagPrimary($0) }
                    )
                )
                .font(.system(size: 12))
                .disabled(!vm.autoAnalyzePrimary)

                if vm.autoAnalyzePrimary {
                    Divider().opacity(0.4)

                    fieldRow(label: "限定域名") {
                        TextField("留空则不限，例如 company.com", text: $vm.filterAllowedDomainsInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .onSubmit { vm.savePrimaryFilterScope() }
                    }

                    fieldRow(label: "本人邮箱") {
                        TextField("可选，例如 me@company.com", text: $vm.filterSelfAddressesInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .onSubmit { vm.savePrimaryFilterScope() }
                    }

                    HStack {
                        Text("自动跳过广告订阅、系统通知与日历回执；填写真实邮箱后同时跳过本人发出邮件。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("保存过滤规则") {
                            vm.savePrimaryFilterScope()
                            vm.statusMessage = "已保存后台邮件过滤规则。"
                            vm.isErrorStatus = false
                        }
                        .controlSize(.mini)
                    }
                }
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
