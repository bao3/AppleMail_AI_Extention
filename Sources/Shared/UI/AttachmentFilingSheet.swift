import AppKit
import SwiftUI

@MainActor
final class AttachmentFilingViewModel: ObservableObject {
    @Published var workspaceURL: URL?
    @Published var payloads: [ExtractedAttachmentPayload] = []
    @Published var planItems: [AttachmentFilingPlanItem] = []
    @Published var isRawDataAvailable = true
    @Published var isLoadingPlan = false
    @Published var isSaving = false
    @Published var savedURLs: [URL] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    let email: ParsedEmailContext
    let analysis: EmailAIAnalysis?
    let preselectedFilename: String?

    private let bookmarkStore: WorkspaceBookmarkStore
    private let rawStore: RawEmailDataStore
    private let organizer: AttachmentOrganizerService
    private let aiClient: AIServiceClient
    private let providerStore: AIProviderStore
    private let keychainStore: KeychainStore

    init(
        email: ParsedEmailContext,
        analysis: EmailAIAnalysis? = nil,
        preselectedFilename: String? = nil,
        bookmarkStore: WorkspaceBookmarkStore = .shared,
        rawStore: RawEmailDataStore = .shared,
        organizer: AttachmentOrganizerService = .shared,
        aiClient: AIServiceClient = .shared,
        providerStore: AIProviderStore = .shared,
        keychainStore: KeychainStore = .shared
    ) {
        self.email = email
        self.analysis = analysis
        self.preselectedFilename = preselectedFilename
        self.bookmarkStore = bookmarkStore
        self.rawStore = rawStore
        self.organizer = organizer
        self.aiClient = aiClient
        self.providerStore = providerStore
        self.keychainStore = keychainStore
        self.workspaceURL = bookmarkStore.workspaceURL
    }

    var selectedCount: Int {
        planItems.filter(\.isSelected).count
    }

    func loadPlan() async {
        workspaceURL = bookmarkStore.workspaceURL
        errorMessage = nil
        statusMessage = nil
        savedURLs = []

        guard let rawData = rawStore.lookup(messageID: email.messageID) else {
            isRawDataAvailable = false
            payloads = []
            planItems = []
            return
        }

        isRawDataAvailable = true
        let extracted = MIMEAttachmentExtractor.extractAttachments(from: rawData, includeInline: false)
        payloads = extracted

        guard !extracted.isEmpty else {
            planItems = []
            return
        }

        guard let rootURL = workspaceURL else {
            planItems = []
            return
        }

        isLoadingPlan = true
        defer { isLoadingPlan = false }

        let activeProfile = providerStore.activeProfile
        let hasAPIKey = keychainStore.hasAPIKey(forProfileID: activeProfile.id)
        let hasProject = !activeProfile.kind.requiresProjectID
            || !activeProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let router: (@Sendable (String, String) async throws -> String)?
        if hasAPIKey && hasProject {
            let client = self.aiClient
            router = { systemPrompt, userPrompt in
                try await client.generateJSONText(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    profile: activeProfile,
                    tier: .fast
                )
            }
        } else {
            router = nil
        }

        let didStart = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        var proposed = await organizer.proposeFilingPlan(
            payloads: extracted,
            email: email,
            analysis: analysis,
            workspaceRootURL: rootURL,
            aiRouter: router
        )

        if let focus = preselectedFilename,
           proposed.contains(where: { $0.originalFilename == focus })
        {
            for idx in proposed.indices {
                proposed[idx].isSelected = (proposed[idx].originalFilename == focus)
            }
        }

        planItems = proposed
    }

    func chooseWorkspace() {
        if let chosen = bookmarkStore.chooseWorkspaceDirectory() {
            workspaceURL = chosen
            Task { await loadPlan() }
        }
    }

    func payload(for item: AttachmentFilingPlanItem) -> ExtractedAttachmentPayload? {
        payloads.first(where: { $0.id == item.payloadID })
    }

    func setSelected(_ selected: Bool, for itemID: String) {
        guard let idx = planItems.firstIndex(where: { $0.id == itemID }) else { return }
        planItems[idx].isSelected = selected
    }

    func updateFolder(_ folder: String, for itemID: String) {
        guard let idx = planItems.firstIndex(where: { $0.id == itemID }) else { return }
        planItems[idx].proposedRelativeFolder = folder
        refreshItemConflict(at: idx)
    }

    func updateFilename(_ filename: String, for itemID: String) {
        guard let idx = planItems.firstIndex(where: { $0.id == itemID }) else { return }
        planItems[idx].proposedFilename = filename
        refreshItemConflict(at: idx)
    }

    private func refreshItemConflict(at idx: Int) {
        guard planItems.indices.contains(idx),
              let payload = payloads.first(where: { $0.id == planItems[idx].payloadID })
        else { return }

        if let refreshed = try? bookmarkStore.withScopedWorkspaceAccess({ rootURL in
            organizer.refreshConflictStatus(for: planItems[idx], payload: payload, workspaceRootURL: rootURL)
        }) {
            planItems[idx] = refreshed
        }
    }

    func pathSafetyWarning(for item: AttachmentFilingPlanItem) -> String? {
        let folder = item.proposedRelativeFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = item.proposedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if file.isEmpty {
            return "文件名不能为空"
        }
        if folder.hasPrefix("/") || file.contains("/") || file.contains("\\") {
            return "仅允许相对路径且文件名不可包含斜杠"
        }
        let segments = folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if !folder.isEmpty && segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") }) {
            return "路径禁止包含空段、.. 或隐藏目录（如 .mailkb）"
        }
        if file == "." || file == ".." || file.hasPrefix(".") {
            return "文件名不能以点开头或为 .."
        }
        return nil
    }

    var hasAnySafetyWarning: Bool {
        planItems.contains(where: { $0.isSelected && pathSafetyWarning(for: $0) != nil })
    }

    func confirmAndSave() {
        guard selectedCount > 0 else { return }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        defer { isSaving = false }

        do {
            let urls = try bookmarkStore.withScopedWorkspaceAccess { rootURL in
                try organizer.executeFilingPlan(
                    items: planItems,
                    payloads: payloads,
                    workspaceRootURL: rootURL
                )
            }
            savedURLs = urls
            statusMessage = "已完成归档（共 \(urls.count) 个文件，未覆盖任何已有文件）。"
            for idx in planItems.indices {
                refreshItemConflict(at: idx)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func formattedSize(for payload: ExtractedAttachmentPayload?) -> String {
        guard let payload else { return "未知大小" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(payload.data.count))
    }
}

/// Apple Mail-style Dry-Run preview sheet for organizing & filing email attachments into an authorized workspace.
public struct AttachmentFilingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: AttachmentFilingViewModel

    public var onClose: (() -> Void)?

    public init(
        email: ParsedEmailContext,
        analysis: EmailAIAnalysis? = nil,
        preselectedFilename: String? = nil,
        onClose: (() -> Void)? = nil
    ) {
        _vm = StateObject(wrappedValue: AttachmentFilingViewModel(
            email: email,
            analysis: analysis,
            preselectedFilename: preselectedFilename
        ))
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    workspaceSection
                    mainContentSection

                    if let error = vm.errorMessage {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if !vm.savedURLs.isEmpty {
                        savedResultSection
                    }
                }
                .padding(12)
            }

            if !vm.planItems.isEmpty {
                Divider().opacity(0.6)
                footerBar
            }
        }
        .frame(minWidth: 500, minHeight: 460)
        .background(MailVibrancyBackground())
        .task {
            await vm.loadPlan()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("附件智能归档预览（Dry-Run）")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(vm.email.subject.isEmpty ? "当前邮件" : vm.email.subject)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(onClose != nil ? "返回" : "关闭") {
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
    }

    private var workspaceSection: some View {
        MailSectionContainer(
            title: "归档工作区根目录",
            systemImage: "externaldrive.badge.checkmark",
            trailing: {
                Button("选择/更换归档根目录…") {
                    vm.chooseWorkspace()
                }
                .controlSize(.mini)
            }
        ) {
            if let root = vm.workspaceURL {
                VStack(alignment: .leading, spacing: 3) {
                    Text(root.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text("仅在您点击「确认归档保存」后按选定目录写入；自动跳过 SHA-256 相同文件，重名自动改名绝不覆盖。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("尚未授权归档工作区目录。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("请点击右上角「选择/更换归档根目录…」授予 macOS 安全作用域目录权限，然后再预览推荐目录并保存。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var mainContentSection: some View {
        if !vm.isRawDataAvailable {
            MailSectionContainer(title: "附件原始数据不可用", systemImage: "tray") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前内存中未找到该邮件的原始 MIME 字节。")
                        .font(.system(size: 12, weight: .medium))
                    Text("可能原因：邮件超过 25 MB 透传阈值、属于 S/MIME 加密邮件，或已被 10 封 LRU 缓存淘汰。请在 Apple Mail 中重新打开一次该邮件，或在宿主 App 中重新导入 .eml 文件后再试。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if vm.payloads.isEmpty {
            MailSectionContainer(title: "未检测到可归档附件", systemImage: "paperclip") {
                Text("本邮件仅包含内嵌签名图片或无可提取的常规附件。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } else if vm.workspaceURL == nil {
            MailSectionContainer(title: "已提取 \(vm.payloads.count) 个非内嵌附件", systemImage: "doc.on.doc") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(vm.payloads) { payload in
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(payload.filename)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Text(vm.formattedSize(for: payload))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } else if vm.isLoadingPlan {
            MailSectionContainer(title: "正在生成归档方案", systemImage: "sparkles") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描工作区目录并智能匹配最佳归档路径…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        } else {
            MailSectionContainer(
                title: "待归档附件计划（\(vm.selectedCount)/\(vm.planItems.count) 已选）",
                systemImage: "list.bullet.rectangle",
                trailing: {
                    Button {
                        Task { await vm.loadPlan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("重新计算推荐路径与冲突状态")
                }
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(vm.planItems.enumerated()), id: \.element.id) { idx, item in
                        planItemRow(item)
                        if idx < vm.planItems.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func planItemRow(_ item: AttachmentFilingPlanItem) -> some View {
        let payload = vm.payload(for: item)
        let warning = vm.pathSafetyWarning(for: item)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { item.isSelected },
                    set: { vm.setSelected($0, for: item.id) }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.originalFilename)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(vm.formattedSize(for: payload))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    if !item.reason.isEmpty {
                        Text(item.reason)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 6)

                conflictBadge(item.conflict)
            }

            if item.isSelected {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("目标目录")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        TextField(
                            "相对子目录（留空则放根目录）",
                            text: Binding(
                                get: { item.proposedRelativeFolder },
                                set: { vm.updateFolder($0, for: item.id) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5, design: .monospaced))

                        if !item.candidateFolders.isEmpty {
                            Menu {
                                ForEach(item.candidateFolders, id: \.self) { candidate in
                                    Button {
                                        vm.updateFolder(candidate, for: item.id)
                                    } label: {
                                        HStack {
                                            Text(candidate)
                                            if candidate == item.proposedRelativeFolder {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("候选", systemImage: "folder")
                                    .font(.system(size: 11))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("从工作区候选目录中选择")
                        }
                    }

                    HStack(spacing: 6) {
                        Text("文件名")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        TextField(
                            "保存文件名",
                            text: Binding(
                                get: { item.proposedFilename },
                                set: { vm.updateFilename($0, for: item.id) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5))
                    }

                    if let warning {
                        Label(warning, systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.red)
                    } else {
                        Text("预计写入：\(item.destinationRelativePath)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private func conflictBadge(_ conflict: AttachmentFilingConflict) -> some View {
        switch conflict {
        case .none:
            Text("新建保存")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
        case let .identicalAlreadyExists(existingURL):
            Text("内容相同 · 跳过")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12))
                .clipShape(Capsule())
                .help("已存在 SHA-256 完全相同的文件：\(existingURL.path)")
        case let .renamedToAvoidOverwrite(suggestedFilename):
            Text("自动改名 → \(suggestedFilename)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
                .lineLimit(1)
                .help("目录中已存在同名异构文件，将自动改名为 \(suggestedFilename) 以避免覆盖")
        }
    }

    private var savedResultSection: some View {
        MailSectionContainer(
            title: vm.statusMessage ?? "归档结果",
            systemImage: "checkmark.circle.fill",
            trailing: {
                Button {
                    vm.revealInFinder(vm.savedURLs)
                } label: {
                    Label("在 Finder 中显示", systemImage: "finder")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
            }
        ) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(vm.savedURLs, id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.green)
                        Text(url.path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            vm.revealInFinder([url])
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中定位此文件")
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Text("所有保存均经安全路径校验，绝不覆盖现有文件")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            if !vm.savedURLs.isEmpty {
                Button("在 Finder 中显示") {
                    vm.revealInFinder(vm.savedURLs)
                }
                .controlSize(.small)
            }
            Button {
                vm.confirmAndSave()
            } label: {
                HStack(spacing: 5) {
                    if vm.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Text(vm.isSaving ? "保存中…" : "确认归档保存 (\(vm.selectedCount))")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.selectedCount == 0 || vm.isSaving || vm.isLoadingPlan || vm.workspaceURL == nil || vm.hasAnySafetyWarning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
