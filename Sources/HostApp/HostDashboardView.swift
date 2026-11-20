import AppKit
import MailKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HostDashboardViewModel: ObservableObject {
    @Published var activeProfile: AIProviderProfile
    @Published var preferredTier: AIModelTier
    @Published var maskedKeyStatus: String?
    @Published var workspacePath: String?
    @Published var cacheCount: Int = 0
    @Published var cacheSizeText: String = "0 B"
    @Published var statusBanner: String?
    @Published var isCheckingConnection = false
    @Published var sampleParsedEmail: ParsedEmailContext
    @Published var showAnalyzerSheet = false
    @Published var showComposeSheet = false
    @Published var showFilingSheet = false
    @Published var showKeychainSheet = false
    @Published var showEMLImporter = false

    private let keychain: KeychainStore
    private let providerStore: AIProviderStore
    private let cacheStore: AnalysisCacheStore
    private let aiClient: AIServiceClient
    private let bookmarkStore: WorkspaceBookmarkStore

    init(
        keychain: KeychainStore = .shared,
        providerStore: AIProviderStore = .shared,
        cacheStore: AnalysisCacheStore = .shared,
        aiClient: AIServiceClient = .shared,
        bookmarkStore: WorkspaceBookmarkStore = .shared
    ) {
        self.keychain = keychain
        self.providerStore = providerStore
        self.cacheStore = cacheStore
        self.aiClient = aiClient
        self.bookmarkStore = bookmarkStore

        let current = providerStore.activeProfile
        self.activeProfile = current
        self.preferredTier = providerStore.preferredTier
        self.maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: current.id)
        self.workspacePath = bookmarkStore.workspaceDisplayPath

        let parsed = MIMEParser.parse(rawData: Self.builtInSampleEMLData)
        self.sampleParsedEmail = parsed
        if !parsed.nonInlineAttachments.isEmpty {
            RawEmailDataStore.shared.store(rawData: Self.builtInSampleEMLData, forMessageID: parsed.messageID)
        }
        refreshStats()
    }

    func refreshStats() {
        let current = providerStore.activeProfile
        activeProfile = current
        preferredTier = providerStore.preferredTier
        maskedKeyStatus = keychain.maskedAPIKeyStatus(forProfileID: current.id)
        workspacePath = bookmarkStore.workspaceDisplayPath
        let stats = cacheStore.cacheStats()
        cacheCount = stats.count
        cacheSizeText = ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
    }

    func selectDefaultTier(_ tier: AIModelTier) {
        preferredTier = tier
        providerStore.setPreferredTier(tier)
        let modelName = activeProfile.modelName(for: tier)
        statusBanner = "默认模型档位已切换为 \(tier.displayName)（\(activeProfile.name) · \(modelName)）。"
    }

    func chooseWorkspaceDirectory() {
        if let url = bookmarkStore.chooseWorkspaceDirectory() {
            workspacePath = url.path
            statusBanner = "✅ 已授权附件归档工作区：\(url.path)"
        }
    }

    func verifyActiveProvider() async {
        refreshStats()
        guard let apiKey = keychain.loadAPIKey(forProfileID: activeProfile.id) else {
            statusBanner = "⚠️ Keychain 中尚未配置「\(activeProfile.name)」的 API Key，请先点击「配置 AI 服务商与凭据」。"
            return
        }
        isCheckingConnection = true
        defer { isCheckingConnection = false }

        do {
            let fastResult = try await aiClient.verifyConnection(
                profile: activeProfile,
                apiKey: apiKey,
                tier: .fast
            )
            let deepResult = try await aiClient.verifyConnection(
                profile: activeProfile,
                apiKey: apiKey,
                tier: .deep
            )
            statusBanner = "✅ 连通性校验通过：\(fastResult) ｜ \(deepResult)"
        } catch {
            statusBanner = "❌ 校验失败：\(error.localizedDescription)"
        }
    }

    func reloadMailExtension() {
        MEExtensionManager.reloadVisibleMessages { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.statusBanner = "刷新 Apple Mail 可见邮件提示：\(error.localizedDescription)"
                } else {
                    self?.statusBanner = "✅ 已通知 Apple Mail 重新加载当前可见邮件横幅。"
                }
            }
        }
    }

    func clearCache() {
        let removed = cacheStore.clearAll()
        refreshStats()
        statusBanner = "已清理 \(removed) 条本地 Message-ID 分析缓存。"
    }

    func loadEMLFile(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            if MIMEParser.isEncryptedEnvelope(data) {
                statusBanner = "⚠️ 该 .eml 为 S/MIME 或 PGP 加密信封，扩展会原样交还 Apple Mail 原生解密。"
                return
            }
            let parsed = MIMEParser.parse(rawData: data)
            sampleParsedEmail = parsed
            if !parsed.nonInlineAttachments.isEmpty {
                RawEmailDataStore.shared.store(rawData: data, forMessageID: parsed.messageID)
            }
            statusBanner = "✅ 已本地解析 \(url.lastPathComponent)：正文 \(parsed.plainBody.count) 字 · 引用 \(parsed.quotedChain.count) 段 · 附件 \(parsed.attachments.count) 个。"
        } catch {
            statusBanner = "❌ 读取 .eml 失败：\(error.localizedDescription)"
        }
    }

    static let builtInSampleEMLData: Data = {
        let raw = """
        Message-ID: <sample-demo-edge-20261120@acme-industrial.example>
        From: "Marcus Vance (Acme Grid)" <marcus.vance@acme-grid.example>
        To: "Sales Engineering" <sales-eng@example.com>
        Cc: "Elena Rostova" <elena.r@acme-grid.example>
        Subject: Re: [Project Helios-III] Updated BOM Pricing & Delivery Schedule for EDS-4012
        Date: Thu, 19 Nov 2026 16:40:00 +0800
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="====MIXED_DEMO===="

        --====MIXED_DEMO====
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: 8bit

        Hi Team,

        Thanks for the revised technical proposal on Project Helios-III (Substation Phase 2).
        Our procurement committee reviewed the updated offer and approved proceeding with the pilot batch, provided we lock in the following terms before Nov 25:

        1. EDS-4012-8GT4XS-HV-T: 120 units @ USD 485.00/unit (FOB Taipei), target ex-factory lead time 4 weeks.
        2. SFP-1GLXLC-T (industrial transceiver): 480 units @ USD 24.50/unit, ship together with switches.
        3. Please confirm whether IEC 61850-3 / IEEE 1613 test certificates can be attached to the final PI.

        Action needed from your side by Friday:
        - Issue updated Proforma Invoice (PI #HELIOS-2026-11B) reflecting the 120-unit tier.
        - Send RoHS & IEC 61850-3 compliance test reports.

        Best regards,
        Marcus Vance
        Principal Grid Systems Architect, Acme Grid Corp.

        On Wed, Nov 18, 2026 at 10:15 AM, Sales Engineering <sales-eng@example.com> wrote:
        > Dear Marcus,
        > Attached is our preliminary quote for Project Helios-III:
        > - EDS-4012-8GT4XS-HV-T: Qty 100-150 @ USD 498/unit, lead time 5 weeks.
        > - We can evaluate a volume discount if PO is confirmed before month-end.

        On Mon, Nov 16, 2026 at 09:00 AM, Elena Rostova <elena.r@acme-grid.example> wrote:
        > Hi all, Acme Grid requires fanless DIN-rail L2+ switches with -40 to 75C rating for Helios-III.
        --====MIXED_DEMO====
        Content-Type: application/pdf; name="Helios-III_BOM_Rev3.pdf"
        Content-Disposition: attachment; filename="Helios-III_BOM_Rev3.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQKJeLjz9MKCg==
        --====MIXED_DEMO====
        Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet; name="=?UTF-8?B?5oql5Lu35piO57uGLnhsc3g=?="
        Content-Disposition: attachment; filename*=UTF-8''%E6%8A%A5%E4%BB%B7%E6%98%8E%E7%BB%86.xlsx
        Content-Transfer-Encoding: base64

        UEsDBBQAAAAIAA==
        --====MIXED_DEMO====--
        """
        return Data(raw.utf8)
    }()
}

struct HostDashboardView: View {
    @StateObject private var vm = HostDashboardViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailArea
        }
        .sheet(isPresented: $vm.showKeychainSheet, onDismiss: { vm.refreshStats() }) {
            KeychainSettingsSheet(
                onSavedKey: {
                    vm.refreshStats()
                },
                onClose: {
                    vm.refreshStats()
                    vm.showKeychainSheet = false
                }
            )
            .frame(width: 520, height: 600)
        }
        .sheet(isPresented: $vm.showAnalyzerSheet, onDismiss: { vm.refreshStats() }) {
            EmailAnalysisPanelView(email: vm.sampleParsedEmail)
                .frame(width: 640, height: 680)
        }
        .sheet(isPresented: $vm.showComposeSheet) {
            ComposeReplyPanelView(
                originalEmail: vm.sampleParsedEmail,
                draftSubject: "Re: \(vm.sampleParsedEmail.subject)",
                recipients: [vm.sampleParsedEmail.from]
            )
            .frame(width: 560, height: 600)
        }
        .sheet(isPresented: $vm.showFilingSheet, onDismiss: { vm.refreshStats() }) {
            AttachmentFilingSheet(
                email: vm.sampleParsedEmail,
                onClose: {
                    vm.refreshStats()
                    vm.showFilingSheet = false
                }
            )
            .frame(width: 600, height: 560)
        }
        .fileImporter(
            isPresented: $vm.showEMLImporter,
            allowedContentTypes: [UTType(filenameExtension: "eml") ?? .emailMessage, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let first = urls.first {
                vm.loadEMLFile(from: first)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AIProviderStore.didChangeNotification)) { _ in
            vm.refreshStats()
        }
    }

    private var sidebar: some View {
        List {
            Section("扩展运行状态") {
                LabeledContent("当前 AI 服务商") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(vm.activeProfile.name)
                            .font(.caption.weight(.medium))
                        Text(vm.activeProfile.kind.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if vm.activeProfile.kind == .vertexAI {
                    LabeledContent("GCP 项目") {
                        if vm.activeProfile.projectID.isEmpty {
                            Text("未配置")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text(vm.activeProfile.projectID)
                                .font(.caption.monospaced())
                        }
                    }
                    LabeledContent("Endpoint 区域") {
                        Text("locations/\(vm.activeProfile.location)")
                            .font(.caption.monospaced())
                    }
                }

                LabeledContent("Keychain 凭据") {
                    if let masked = vm.maskedKeyStatus {
                        Text(masked)
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("未配置")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                LabeledContent("归档工作区") {
                    if let path = vm.workspacePath {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    } else {
                        Text("未授权")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("本地缓存") {
                    Text("\(vm.cacheCount) 封 · \(vm.cacheSizeText)")
                        .font(.caption)
                }
            }

            Section("默认模型档位") {
                Picker("默认模型档位", selection: Binding(
                    get: { vm.preferredTier },
                    set: { vm.selectDefaultTier($0) }
                )) {
                    ForEach(AIModelTier.allCases) { tier in
                        Text(tier.shortLabel).tag(tier)
                    }
                }
                .pickerStyle(.segmented)

                Text("\(vm.preferredTier.subtitle) · \(vm.activeProfile.modelName(for: vm.preferredTier))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("快捷操作") {
                Button {
                    vm.showKeychainSheet = true
                } label: {
                    Label("配置 AI 服务商与凭据", systemImage: "key.fill")
                }

                Button {
                    vm.chooseWorkspaceDirectory()
                } label: {
                    Label("选择附件归档目录…", systemImage: "folder.badge.plus")
                }

                Button {
                    Task { await vm.verifyActiveProvider() }
                } label: {
                    Label(vm.isCheckingConnection ? "正在校验…" : "测试当前 AI 连通性", systemImage: "checkmark.seal")
                }
                .disabled(vm.isCheckingConnection)

                Button {
                    vm.reloadMailExtension()
                } label: {
                    Label("刷新 Apple Mail 扩展", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
                } label: {
                    Label("打开 Apple Mail", systemImage: "envelope.fill")
                }

                Button(role: .destructive) {
                    vm.clearCache()
                } label: {
                    Label("清空本地分析缓存", systemImage: "trash")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 270)
    }

    private var detailArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Mail AI 扩展控制台")
                        .font(.title2.bold())
                    Text("MailKit 原生扩展：阅读顶部横幅「AI 汇总分析」（SSE 流式呈现 + 历史报价参考 + 附件智能归档）+ 写信工具栏「AI 双语回复助手」。邮件原文透传不加密、不篡改。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let banner = vm.statusBanner {
                    Text(banner)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                GroupBox("如何在 Apple Mail 中启用扩展") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 打开系统 **邮件 (Mail.app)** → 菜单栏 **邮件 → 设置… (⌘,)** → **扩展**。")
                        Text("2. 在左侧勾选启用 **AI 邮件汇总与双语回复**。")
                        Text("3. 点开任意邮件，顶部横幅即显示「**AI 汇总分析**」按钮；点写信窗口工具栏扩展图标即可使用双语回复草稿。")
                        Text("4. 支持 **Vertex AI / Gemini API Studio / OpenAI 兼容接口 / Anthropic Claude**，API Key 仅由 macOS Keychain 读取；附件归档仅在授权工作区目录并点击确认后写入，绝不覆盖现有文件。")
                    }
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("本地 MIME 提取与 AI 面板联调沙盒") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.sampleParsedEmail.subject)
                                    .font(.headline)
                                Text("发件人: \(vm.sampleParsedEmail.from) · 引用段: \(vm.sampleParsedEmail.quotedChain.count) · 附件: \(vm.sampleParsedEmail.attachments.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("导入 .eml 测试") {
                                vm.showEMLImporter = true
                            }
                        }

                        if !vm.sampleParsedEmail.attachments.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(vm.sampleParsedEmail.attachments) { att in
                                    Label("\(att.filename) (\(att.formattedSize))", systemImage: "paperclip")
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                vm.showAnalyzerSheet = true
                            } label: {
                                Label("预览「AI 汇总分析」面板", systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                vm.showComposeSheet = true
                            } label: {
                                Label("预览「AI 双语回复」面板", systemImage: "square.and.pencil")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                vm.showFilingSheet = true
                            } label: {
                                Label("预览「附件智能归档」面板", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}
