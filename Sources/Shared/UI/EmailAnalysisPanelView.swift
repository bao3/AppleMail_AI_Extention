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
    @Published var addedReminderKeys: Set<String>
    @Published var addingTodoIDs: Set<String> = []
    @Published var reminderPermissionDenied = false

    let email: ParsedEmailContext

    private let cacheStore: AnalysisCacheStore
    private let keychainStore: KeychainStore
    private let client: VertexGeminiClient
    private let reminderService: ReminderService

    init(
        email: ParsedEmailContext,
        cacheStore: AnalysisCacheStore = .shared,
        keychainStore: KeychainStore = .shared,
        client: VertexGeminiClient = .shared,
        reminderService: ReminderService = .shared
    ) {
        self.email = email
        self.cacheStore = cacheStore
        self.keychainStore = keychainStore
        self.client = client
        self.reminderService = reminderService
        self.selectedModel = keychainStore.loadPreferredModel()
        self.hasAPIKey = keychainStore.hasAPIKey()
        self.addedReminderKeys = reminderService.loadAddedKeys()
    }

    func loadInitial() async {
        hasAPIKey = keychainStore.hasAPIKey()
        addedReminderKeys = reminderService.loadAddedKeys()

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

    func isReminderAdded(_ todo: EmailTodoItem) -> Bool {
        let key = todo.reminderStorageKey(messageID: email.messageID)
        return addedReminderKeys.contains(key)
    }

    func addTodoToReminders(_ todo: EmailTodoItem) async {
        guard let analysis else { return }
        let key = todo.reminderStorageKey(messageID: email.messageID)
        guard !addedReminderKeys.contains(key), !addingTodoIDs.contains(todo.id) else { return }

        addingTodoIDs.insert(todo.id)
        defer { addingTodoIDs.remove(todo.id) }

        do {
            let schedule = try await reminderService.addReminder(for: todo, email: email, analysis: analysis)
            addedReminderKeys.insert(key)
            reminderPermissionDenied = false
            errorMessage = nil
            showToast("已加入提醒事项 · \(schedule.scheduleLabel)")
        } catch let err as ReminderServiceError {
            if case .permissionDenied = err {
                reminderPermissionDenied = true
            }
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyMarkdownSummary() {
        guard let analysis else { return }
        let report = analysis.toMarkdownReport(subject: email.subject)
        copyToPasteboard(report, toast: "已复制分析纪要")
    }

    func copyText(_ text: String, label: String) {
        copyToPasteboard(text, toast: "已复制\(label)")
    }

    private func copyToPasteboard(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(toast)
    }

    private func showToast(_ toast: String) {
        copiedToast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
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
                    inspectorHeader
                    Divider().opacity(0.6)
                    contentBody
                    if let analysis = vm.analysis {
                        Divider().opacity(0.6)
                        compactFooter(analysis)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 540)
        .background(MailVibrancyBackground())
        .task {
            await vm.loadInitial()
        }
    }

    // MARK: - Inspector Header

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(vm.email.subject.isEmpty ? "（无主题邮件）" : vm.email.subject)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    MailModelMenuButton(selection: Binding(
                        get: { vm.selectedModel },
                        set: { vm.selectModel($0) }
                    ))

                    if let current = vm.analysis, current.modelUsed != vm.selectedModel.rawValue {
                        Button("重跑") {
                            Task { await vm.analyze(forceRefresh: true) }
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isLoading)
                    }

                    MailIconActionButton(
                        systemImage: "doc.on.doc",
                        helpText: "复制 Markdown 分析纪要",
                        isDisabled: vm.analysis == nil
                    ) {
                        vm.copyMarkdownSummary()
                    }

                    MailIconActionButton(
                        systemImage: "arrow.clockwise",
                        helpText: "使用当前模型重新分析",
                        isDisabled: vm.isLoading
                    ) {
                        Task { await vm.analyze(forceRefresh: true) }
                    }

                    MailIconActionButton(
                        systemImage: "gearshape",
                        helpText: "凭据与自动化设置"
                    ) {
                        showKeychainSheet = true
                    }
                }
            }

            HStack(spacing: 6) {
                Text(vm.email.from.isEmpty ? "未知发件人" : vm.email.from)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !vm.email.attachments.isEmpty {
                    Text("· 📎 \(vm.email.attachments.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let analysis = vm.analysis, analysis.resolvedFlag != .none {
                    MailFlagBadge(flag: analysis.resolvedFlag, reason: analysis.flagReason)
                }

                Spacer(minLength: 8)

                if let toast = vm.copiedToast {
                    Text(toast)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else if vm.analysis != nil {
                    Text(vm.isFromCache ? "已缓存" : "实时")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Body

    @ViewBuilder
    private var contentBody: some View {
        if vm.isLoading && vm.analysis == nil {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在摘要分析（\(vm.selectedModel.displayName)）…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("已提取正文 \(vm.email.plainBody.count) 字 · 引用 \(vm.email.quotedChain.count) 段 · 附件 \(vm.email.attachments.count) 个")
                    .font(.system(size: 11))
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
                VStack(alignment: .leading, spacing: 10) {
                    if vm.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在使用 \(vm.selectedModel.displayName) 重新分析…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if let error = vm.errorMessage {
                        errorBanner(error)
                    }

                    summarySection(analysis)

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
                .padding(12)
            }
        } else {
            VStack(spacing: 12) {
                Text("已本地提取邮件正文与附件信息")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("开始 AI 摘要分析") {
                    Task { await vm.analyze(forceRefresh: false) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if vm.reminderPermissionDenied {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var missingKeyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("尚未配置 Vertex AI 凭据")
                .font(.system(size: 14, weight: .semibold))
            Text("点击下方按钮填入 GCP Project ID 与 Keychain API Key。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("配置凭据") {
                showKeychainSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorPlaceholder(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.red)
            Text("分析未能完成")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: 8) {
                Button("重试") {
                    Task { await vm.analyze(forceRefresh: true) }
                }
                .buttonStyle(.borderedProminent)
                Button("检查设置") {
                    showKeychainSheet = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Sections

    private func summarySection(_ analysis: EmailAIAnalysis) -> some View {
        MailSectionContainer(title: "摘要结论", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                Text(analysis.headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !analysis.coreConclusions.isEmpty {
                    Divider().opacity(0.6)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(analysis.coreConclusions.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 7) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.65))
                                    .frame(width: 4.5, height: 4.5)
                                    .padding(.top, 5.5)
                                Text(item)
                                    .font(.system(size: 12.5))
                                    .lineSpacing(2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func todosSection(_ todos: [EmailTodoItem]) -> some View {
        MailSectionContainer(
            title: "待办事项",
            systemImage: "checklist",
            trailing: {
                Text("\(todos.count) 项 · 点 + 加入提醒")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(todos.enumerated()), id: \.element.id) { idx, todo in
                    let isAdded = vm.isReminderAdded(todo)
                    let isAdding = vm.addingTodoIDs.contains(todo.id)
                    let schedule = ReminderScheduleCalculator.calculate(
                        dueDateISO: todo.dueDateISO,
                        deadlineText: todo.deadline,
                        emailDateString: vm.email.dateString
                    )

                    HStack(alignment: .center, spacing: 10) {
                        Circle()
                            .fill(priorityDotColor(todo))
                            .frame(width: 6.5, height: 6.5)

                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(todo.task)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                if !todo.owner.isEmpty {
                                    Text(todo.owner)
                                }
                                Text("·")
                                Text(schedule.scheduleLabel)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 6)

                        if isAdding {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 22, height: 22)
                        } else {
                            Button {
                                Task { await vm.addTodoToReminders(todo) }
                            } label: {
                                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(isAdded ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(isAdded)
                            .help(isAdded ? "已添加到苹果提醒事项" : "添加到苹果提醒事项（\(schedule.scheduleLabel)）")
                        }
                    }
                    .padding(.vertical, 6)

                    if idx < todos.count - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }
        }
    }

    private func priorityDotColor(_ todo: EmailTodoItem) -> Color {
        switch todo.normalizedPriority {
        case "high": return .red
        case "low": return .secondary.opacity(0.55)
        default: return .orange
        }
    }

    private func businessSection(_ biz: BusinessElements) -> some View {
        MailSectionContainer(title: "项目与商务要素", systemImage: "briefcase") {
            VStack(alignment: .leading, spacing: 8) {
                if !biz.projects.isEmpty {
                    keyValueTagRow(label: "项目", items: biz.projects, monospaced: false)
                }
                if !biz.customers.isEmpty {
                    keyValueTagRow(label: "客户", items: biz.customers, monospaced: false)
                }
                if !biz.models.isEmpty {
                    keyValueTagRow(label: "型号", items: biz.models, monospaced: true)
                }

                if !biz.pricing.isEmpty {
                    if !biz.projects.isEmpty || !biz.customers.isEmpty || !biz.models.isEmpty {
                        Divider().opacity(0.55)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(biz.pricing.enumerated()), id: \.element.id) { idx, row in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(row.itemOrModel.isEmpty ? "未指定型号" : row.itemOrModel)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .textSelection(.enabled)
                                    Spacer()
                                    if let unitPrice = row.unitPrice, !unitPrice.isEmpty {
                                        let currency = row.currency ?? ""
                                        Text("\(currency) \(unitPrice)".trimmingCharacters(in: .whitespaces))
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .textSelection(.enabled)
                                    }
                                }

                                HStack(spacing: 10) {
                                    if let qty = row.quantity, !qty.isEmpty {
                                        Text("数量 \(qty)")
                                    }
                                    if let terms = row.termsOrLeadTime, !terms.isEmpty {
                                        Text("交期/条款 \(terms)")
                                    }
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                                if let notes = row.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 5)

                            if idx < biz.pricing.count - 1 {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
            }
        }
    }

    private func keyValueTagRow(label: String, items: [String], monospaced: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 3)

            MailWrapLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11.5))
                        .textSelection(.enabled)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.055))
                        .overlay(
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                        )
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func translationSection(_ translation: String) -> some View {
        MailSectionContainer(
            title: "中文梳理",
            systemImage: "character.bubble",
            trailing: {
                Button {
                    vm.copyText(translation, label: "中文梳理")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("复制译文")
            }
        ) {
            Text(translation)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timelineSection(_ events: [TimelineEvent]) -> some View {
        MailSectionContainer(title: "往来脉络", systemImage: "clock") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                    HStack(alignment: .top, spacing: 9) {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(Color.secondary.opacity(0.75))
                                .frame(width: 6, height: 6)
                                .padding(.top, 4.5)
                            if idx < events.count - 1 {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor))
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(event.timeOrStep)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                if !event.actor.isEmpty {
                                    Text("· \(event.actor)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(event.summary)
                                .font(.system(size: 12.5))
                                .lineSpacing(1.5)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func attachmentsSection(_ attachments: [AttachmentSummary]) -> some View {
        MailSectionContainer(title: "附件 (\(attachments.count))", systemImage: "paperclip") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isInline ? "photo" : "doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(item.filename)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.mimeType) · \(item.formattedSize)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)

                    if idx < attachments.count - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }
        }
    }

    private var localExtractionDisclosure: some View {
        DisclosureGroup("本地 MIME 原文与引用（\(vm.email.quotedChain.count) 段）", isExpanded: $showRawLocalExtraction) {
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.email.plainBody.isEmpty ? "(正文为空)" : vm.email.plainBody)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(vm.email.quotedChain) { quote in
                    Divider().opacity(0.5)
                    Text("[\(quote.index)] \(quote.attribution)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(quote.content)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private func compactFooter(_ analysis: EmailAIAnalysis) -> some View {
        HStack(spacing: 6) {
            Text(analysis.modelUsed)
            if let ms = analysis.latencyMs {
                Text("· \(ms) ms")
            }
            if let prompt = analysis.promptTokens, let out = analysis.outputTokens {
                Text("· \(prompt)/\(out) tok")
            }
            Spacer()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
