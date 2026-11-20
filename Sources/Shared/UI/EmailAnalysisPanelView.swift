import AppKit
import SwiftUI

@MainActor
final class EmailAnalysisViewModel: ObservableObject {
    @Published var selectedModel: GeminiModel
    @Published var analysis: EmailAIAnalysis?
    @Published var isFromCache = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasAPIKey: Bool
    @Published var copiedToast: String?

    let email: ParsedEmailContext

    private let cacheStore: AnalysisCacheStore
    private let keychainStore: KeychainStore
    private let client: VertexGeminiClient

    init(
        email: ParsedEmailContext,
        cacheStore: AnalysisCacheStore = .shared,
        keychainStore: KeychainStore = .shared,
        client: VertexGeminiClient = .shared
    ) {
        self.email = email
        self.cacheStore = cacheStore
        self.keychainStore = keychainStore
        self.client = client
        self.selectedModel = keychainStore.loadPreferredModel()
        self.hasAPIKey = keychainStore.hasAPIKey()
    }

    func loadInitial() async {
        hasAPIKey = keychainStore.hasAPIKey()
        if let cached = cacheStore.load(forMessageID: email.messageID) {
            analysis = cached
            isFromCache = true
            if let cachedModel = GeminiModel(rawValue: cached.modelUsed) {
                selectedModel = cachedModel
            }
            return
        }

        if let inFlight = await BackgroundAnalysisCoordinator.shared.inFlightTask(forMessageID: email.messageID) {
            isLoading = true
            let result = try? await inFlight.value
            isLoading = false
            if let result {
                analysis = result
                isFromCache = true
                if let cachedModel = GeminiModel(rawValue: result.modelUsed) {
                    selectedModel = cachedModel
                }
                return
            }
            if let cached = cacheStore.load(forMessageID: email.messageID) {
                analysis = cached
                isFromCache = true
                if let cachedModel = GeminiModel(rawValue: cached.modelUsed) {
                    selectedModel = cachedModel
                }
                return
            }
        }

        if hasAPIKey {
            await analyze(forceRefresh: false)
        }
    }

    func selectModel(_ model: GeminiModel) {
        selectedModel = model
        keychainStore.savePreferredModel(model)
    }

    func analyze(forceRefresh: Bool) async {
        hasAPIKey = keychainStore.hasAPIKey()
        guard let apiKey = keychainStore.loadAPIKey() else {
            errorMessage = VertexGeminiError.missingAPIKey.errorDescription
            return
        }

        if !forceRefresh, let cached = cacheStore.load(forMessageID: email.messageID) {
            analysis = cached
            isFromCache = true
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.analyzeEmail(email, model: selectedModel, apiKey: apiKey)
            try cacheStore.save(result, forMessageID: email.messageID)
            analysis = result
            isFromCache = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyMarkdownSummary() {
        guard let analysis else { return }
        let report = analysis.toMarkdownReport(subject: email.subject)
        copyToPasteboard(report, toast: "已复制完整分析纪要")
    }

    func copyText(_ text: String, label: String) {
        copyToPasteboard(text, toast: "已复制\(label)")
    }

    private func copyToPasteboard(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedToast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if self.copiedToast == toast {
                self.copiedToast = nil
            }
        }
    }
}

public struct EmailAnalysisPanelView: View {
    @StateObject private var vm: EmailAnalysisViewModel
    @State private var showKeychainSheet = false
    @State private var showRawLocalExtraction = false

    public init(email: ParsedEmailContext) {
        _vm = StateObject(wrappedValue: EmailAnalysisViewModel(email: email))
    }

    public var body: some View {
        Group {
            if showKeychainSheet {
                KeychainSettingsSheet(
                    onSavedKey: {
                        showKeychainSheet = false
                        Task {
                            await vm.analyze(forceRefresh: false)
                        }
                    },
                    onClose: {
                        showKeychainSheet = false
                    }
                )
            } else {
                VStack(spacing: 0) {
                    headerBar
                    Divider()
                    contentBody
                    if let analysis = vm.analysis {
                        Divider()
                        footerBar(analysis)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await vm.loadInitial()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.email.subject.isEmpty ? "（无主题邮件）" : vm.email.subject)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(vm.email.from.isEmpty ? "未知发件人" : vm.email.from)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !vm.email.attachments.isEmpty {
                            Text("· 📎 \(vm.email.attachments.count) 附件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if vm.analysis != nil {
                            cacheStatusBadge
                        }
                    }
                }

                Spacer()

                if let toast = vm.copiedToast {
                    Text(toast)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {
                Picker("模型", selection: Binding(
                    get: { vm.selectedModel },
                    set: { vm.selectModel($0) }
                )) {
                    ForEach(GeminiModel.allCases) { model in
                        Text(model.shortLabel).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)

                if let current = vm.analysis, current.modelUsed != vm.selectedModel.rawValue {
                    Button("用 \(vm.selectedModel.shortLabel) 重跑") {
                        Task { await vm.analyze(forceRefresh: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    Task { await vm.analyze(forceRefresh: true) }
                } label: {
                    Label("重新分析", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(vm.isLoading)

                Button {
                    vm.copyMarkdownSummary()
                } label: {
                    Label("复制纪要", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(vm.analysis == nil)

                Button {
                    showKeychainSheet = true
                } label: {
                    Label("Key", systemImage: "key.fill")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var cacheStatusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: vm.isFromCache ? "internaldrive.fill" : "sparkles")
            Text(vm.isFromCache ? "本地缓存命中" : "实时生成")
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(vm.isFromCache ? Color.blue.opacity(0.14) : Color.purple.opacity(0.14))
        .foregroundStyle(vm.isFromCache ? .blue : .purple)
        .clipShape(Capsule())
    }

    // MARK: - Body

    @ViewBuilder
    private var contentBody: some View {
        if vm.isLoading && vm.analysis == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在通过 Vertex AI (\(vm.selectedModel.displayName) · global) 分析邮件…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("本地已提取正文 \(vm.email.plainBody.count) 字 · 引用段 \(vm.email.quotedChain.count) 段 · 附件 \(vm.email.attachments.count) 个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if !vm.hasAPIKey && vm.analysis == nil {
            missingKeyPlaceholder
        } else if let error = vm.errorMessage, vm.analysis == nil {
            errorPlaceholder(error)
        } else if let analysis = vm.analysis {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if vm.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在使用 \(vm.selectedModel.displayName) 重新分析…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if let error = vm.errorMessage {
                        Text("⚠️ \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    conclusionsSection(analysis)

                    if !analysis.todos.isEmpty {
                        todosSection(analysis.todos)
                    }

                    if !analysis.businessElements.isEmpty {
                        businessSection(analysis.businessElements)
                    }

                    if !analysis.plainChineseTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        translationSection(analysis.plainChineseTranslation)
                    }

                    if !analysis.timeline.isEmpty {
                        timelineSection(analysis.timeline)
                    }

                    if !vm.email.attachments.isEmpty {
                        attachmentsSection(vm.email.attachments)
                    }

                    localExtractionDisclosure
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 12) {
                Text("已本地提取邮件正文与附件名，点击下方按钮开始 AI 汇总分析。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("立即 AI 汇总分析") {
                    Task { await vm.analyze(forceRefresh: false) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var missingKeyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("尚未在 macOS Keychain 中配置 Vertex AI API Key")
                .font(.headline)
            Text("请点击下方按钮配置 GCP Project ID 与 Vertex AI API Key，或通过终端运行 `sync_gcloud_key_to_keychain.sh`。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("配置 Keychain API Key") {
                showKeychainSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorPlaceholder(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text("AI 分析未能完成")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("重试") {
                    Task { await vm.analyze(forceRefresh: true) }
                }
                .buttonStyle(.borderedProminent)
                Button("检查 Keychain") {
                    showKeychainSheet = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Analysis Cards

    private func conclusionsSection(_ analysis: EmailAIAnalysis) -> some View {
        sectionCard(title: "核心结论", icon: "sparkles", tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(analysis.headline)
                    .font(.subheadline.weight(.semibold))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                ForEach(Array(analysis.coreConclusions.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 16, alignment: .trailing)
                        Text(item)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func todosSection(_ todos: [EmailTodoItem]) -> some View {
        sectionCard(title: "待办事项 (\(todos.count))", icon: "checklist", tint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(todos) { todo in
                    HStack(alignment: .top, spacing: 8) {
                        priorityBadge(todo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(todo.task)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                if !todo.owner.isEmpty {
                                    Label(todo.owner, systemImage: "person")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let dl = todo.deadline, !dl.isEmpty {
                                    Label(dl, systemImage: "calendar")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func priorityBadge(_ todo: EmailTodoItem) -> some View {
        let color: Color = switch todo.normalizedPriority {
        case "high": .red
        case "low": .secondary
        default: .orange
        }
        return Text(todo.priorityLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func businessSection(_ biz: BusinessElements) -> some View {
        sectionCard(title: "项目 / 客户 / 型号 / 价格要素", icon: "briefcase.fill", tint: .teal) {
            VStack(alignment: .leading, spacing: 10) {
                if !biz.projects.isEmpty {
                    labeledTagsRow(label: "项目", items: biz.projects, tint: .indigo)
                }
                if !biz.customers.isEmpty {
                    labeledTagsRow(label: "客户", items: biz.customers, tint: .teal)
                }
                if !biz.models.isEmpty {
                    labeledTagsRow(label: "型号", items: biz.models, tint: .cyan)
                }

                if !biz.pricing.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("报价与交期明细")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(biz.pricing) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.itemOrModel.isEmpty ? "未指定型号" : row.itemOrModel)
                                        .font(.callout.weight(.semibold))
                                        .textSelection(.enabled)
                                    Spacer()
                                    if let unitPrice = row.unitPrice, !unitPrice.isEmpty {
                                        let currency = row.currency ?? ""
                                        Text("\(currency) \(unitPrice)".trimmingCharacters(in: .whitespaces))
                                            .font(.callout.weight(.bold))
                                            .foregroundStyle(.teal)
                                            .textSelection(.enabled)
                                    }
                                }

                                HStack(spacing: 12) {
                                    if let qty = row.quantity, !qty.isEmpty {
                                        Text("数量: \(qty)")
                                    }
                                    if let terms = row.termsOrLeadTime, !terms.isEmpty {
                                        Text("条款/交期: \(terms)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                                if let notes = row.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }
    }

    private func labeledTagsRow(label: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowTagGrid(items: items, tint: tint)
        }
    }

    private func translationSection(_ translation: String) -> some View {
        sectionCard(
            title: "英文通俗中译 / 白话梳理",
            icon: "character.bubble.fill",
            tint: .green,
            trailingAction: {
                Button {
                    vm.copyText(translation, label: "通俗中译")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("复制译文")
            }
        ) {
            Text(translation)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timelineSection(_ events: [TimelineEvent]) -> some View {
        sectionCard(title: "长信时间线 (\(events.count))", icon: "clock.arrow.circlepath", tint: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            if idx < events.count - 1 {
                                Rectangle()
                                    .fill(Color.purple.opacity(0.25))
                                    .frame(width: 1.5)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(event.timeOrStep)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.purple)
                                if !event.actor.isEmpty {
                                    Text("· \(event.actor)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(event.summary)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func attachmentsSection(_ attachments: [AttachmentSummary]) -> some View {
        sectionCard(title: "本地提取附件名 (\(attachments.count))", icon: "paperclip", tint: .gray) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isInline ? "photo" : "doc.fill")
                            .foregroundStyle(.secondary)
                        Text(item.filename)
                            .font(.caption.weight(.medium))
                            .textSelection(.enabled)
                        Spacer()
                        Text("\(item.mimeType) · \(item.formattedSize)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var localExtractionDisclosure: some View {
        DisclosureGroup("本地 MIME 提取原文与引用链（\(vm.email.quotedChain.count) 段引用）", isExpanded: $showRawLocalExtraction) {
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.email.plainBody.isEmpty ? "(正文为空)" : vm.email.plainBody)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(vm.email.quotedChain) { quote in
                    Divider()
                    Text("[\(quote.index)] \(quote.attribution)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(quote.content)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption.weight(.medium))
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private func footerBar(_ analysis: EmailAIAnalysis) -> some View {
        HStack(spacing: 8) {
            Text("模型: \(analysis.modelUsed)")
            Text("·")
            Text("Message-ID: \(analysis.messageID)")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let prompt = analysis.promptTokens, let out = analysis.outputTokens {
                Text("Tokens \(prompt)/\(out)")
            }
            if let ms = analysis.latencyMs {
                Text("\(ms)ms")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: - Card Shell

    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder trailingAction: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                trailingAction()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Simple wrapping tag flow view compatible with macOS 14+.
private struct FlowTagGrid: View {
    let items: [String]
    let tint: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tint.opacity(0.12))
                    .foregroundStyle(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
