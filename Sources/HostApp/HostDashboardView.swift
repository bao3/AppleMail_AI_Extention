import AppKit
import MailKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HostDashboardViewModel: ObservableObject {
    @Published var projectID: String = ""
    @Published var maskedKeyStatus: String?
    @Published var preferredModel: GeminiModel
    @Published var cacheCount: Int = 0
    @Published var cacheSizeText: String = "0 B"
    @Published var statusBanner: String?
    @Published var isCheckingConnection = false
    @Published var sampleParsedEmail: ParsedEmailContext
    @Published var showAnalyzerSheet = false
    @Published var showComposeSheet = false
    @Published var showKeychainSheet = false
    @Published var showEMLImporter = false

    private let keychain: KeychainStore
    private let cacheStore: AnalysisCacheStore
    private let client: VertexGeminiClient

    init(
        keychain: KeychainStore = .shared,
        cacheStore: AnalysisCacheStore = .shared,
        client: VertexGeminiClient = .shared
    ) {
        self.keychain = keychain
        self.cacheStore = cacheStore
        self.client = client
        self.projectID = keychain.loadProjectID()
        self.maskedKeyStatus = keychain.maskedAPIKeyStatus()
        self.preferredModel = keychain.loadPreferredModel()
        self.sampleParsedEmail = MIMEParser.parse(rawData: Self.builtInSampleEMLData)
        refreshStats()
    }

    func refreshStats() {
        projectID = keychain.loadProjectID()
        maskedKeyStatus = keychain.maskedAPIKeyStatus()
        preferredModel = keychain.loadPreferredModel()
        let stats = cacheStore.cacheStats()
        cacheCount = stats.count
        cacheSizeText = ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
    }

    func selectDefaultModel(_ model: GeminiModel) {
        preferredModel = model
        keychain.savePreferredModel(model)
        statusBanner = "默认模型已切换为 \(model.displayName) (\(model.rawValue))。"
    }

    func verifyBothModels() async {
        guard let apiKey = keychain.loadAPIKey() else {
            statusBanner = "⚠️ Keychain 中尚未配置 API Key，请先点击「配置 Keychain」。"
            return
        }
        isCheckingConnection = true
        defer { isCheckingConnection = false }

        do {
            let t1 = try await client.verifyAPIKeyAndModel(apiKey: apiKey, model: .flash38)
            let t2 = try await client.verifyAPIKeyAndModel(apiKey: apiKey, model: .carbon4)
            statusBanner = "✅ 双模型 countTokens 零成本校验通过：gemini-3.8-flash (\(t1)) · gemini-4-carbon (\(t2))"
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
            sampleParsedEmail = MIMEParser.parse(rawData: data)
            statusBanner = "✅ 已本地解析 \(url.lastPathComponent)：正文 \(sampleParsedEmail.plainBody.count) 字 · 引用 \(sampleParsedEmail.quotedChain.count) 段 · 附件 \(sampleParsedEmail.attachments.count) 个。"
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
            KeychainSettingsSheet {
                vm.refreshStats()
            }
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
        .fileImporter(
            isPresented: $vm.showEMLImporter,
            allowedContentTypes: [UTType(filenameExtension: "eml") ?? .emailMessage, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let first = urls.first {
                vm.loadEMLFile(from: first)
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("扩展运行状态") {
                LabeledContent("GCP 项目") {
                    if vm.projectID.isEmpty {
                        Text("未配置")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(vm.projectID)
                            .font(.caption.monospaced())
                    }
                }
                LabeledContent("Endpoint 区域") {
                    Text("locations/\(GeminiModel.vertexLocation)")
                        .font(.caption.monospaced())
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
                LabeledContent("本地缓存") {
                    Text("\(vm.cacheCount) 封 · \(vm.cacheSizeText)")
                        .font(.caption)
                }
            }

            Section("默认模型切换") {
                Picker("默认模型", selection: Binding(
                    get: { vm.preferredModel },
                    set: { vm.selectDefaultModel($0) }
                )) {
                    ForEach(GeminiModel.allCases) { model in
                        Text("\(model.shortLabel)").tag(model)
                    }
                }
                .pickerStyle(.segmented)

                Text(vm.preferredModel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("快捷操作") {
                Button {
                    vm.showKeychainSheet = true
                } label: {
                    Label("配置 Keychain API Key", systemImage: "key.fill")
                }

                Button {
                    Task { await vm.verifyBothModels() }
                } label: {
                    Label(vm.isCheckingConnection ? "正在校验…" : "零成本测试双模型", systemImage: "checkmark.seal")
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
                    Text("MailKit 原生扩展：阅读顶部横幅「AI 汇总分析」+ 写信工具栏「AI 双语回复助手」。邮件原文透传不加密、不篡改。")
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
                        Text("4. 本扩展使用 `com.apple.security.network.client` 沙盒网络权限直连 Vertex AI `locations/global`，API Key 仅由 macOS Keychain 读取。")
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
