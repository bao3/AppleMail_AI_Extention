import AppKit
import SwiftUI

@MainActor
final class EmailAnalysisViewModel: ObservableObject {
    @Published var activeProfile: AIProviderProfile
    @Published var profiles: [AIProviderProfile]
    @Published var selectedTier: AIModelTier
    @Published var analysis: EmailAIAnalysis?
    @Published var partialSnapshot: PartialAnalysisSnapshot?
    @Published var priceGroups: [SKUPriceComparisonGroup] = []
    @Published var isLoadingPrices = false
    @Published var isFromCache = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasCredentials: Bool
    @Published var copiedToast: String?
    @Published var addedReminderKeys: Set<String>
    @Published var addingTodoIDs: Set<String> = []
    @Published var reminderPermissionDenied = false

    let email: ParsedEmailContext

    private let cacheStore: AnalysisCacheStore
    private let keychainStore: KeychainStore
    private let providerStore: AIProviderStore
    private let aiClient: AIServiceClient
    private let reminderService: ReminderService
    private let priceService: HistoricalPriceLookupService
    private var priceLookupTask: Task<Void, Never>?

    init(
        email: ParsedEmailContext,
        cacheStore: AnalysisCacheStore = .shared,
        keychainStore: KeychainStore = .shared,
        providerStore: AIProviderStore = .shared,
        aiClient: AIServiceClient = .shared,
        reminderService: ReminderService = .shared,
        priceService: HistoricalPriceLookupService = .shared
    ) {
        self.email = email
        self.cacheStore = cacheStore
        self.keychainStore = keychainStore
        self.providerStore = providerStore
        self.aiClient = aiClient
        self.reminderService = reminderService
        self.priceService = priceService

        let currentProfile = providerStore.activeProfile
        self.activeProfile = currentProfile
        self.profiles = providerStore.profiles
        self.selectedTier = providerStore.preferredTier
        self.hasCredentials = Self.checkCredentials(profile: currentProfile, keychainStore: keychainStore)
        self.addedReminderKeys = reminderService.loadAddedKeys()
    }

    var targetModelName: String {
        activeProfile.modelName(for: selectedTier)
    }

    func refreshProviderState() {
        let currentProfile = providerStore.activeProfile
        activeProfile = currentProfile
        profiles = providerStore.profiles
        selectedTier = providerStore.preferredTier
        hasCredentials = Self.checkCredentials(profile: currentProfile, keychainStore: keychainStore)
    }

    func loadInitial() async {
        refreshProviderState()
        addedReminderKeys = reminderService.loadAddedKeys()
        triggerPriceLookup(analysis: nil)

        if let cached = cacheStore.load(forMessageID: email.messageID) {
            analysis = cached
            isFromCache = true
            syncTierIfMatchingCurrentProfile(modelUsed: cached.modelUsed)
            triggerPriceLookup(analysis: cached)
            return
        }

        if let inFlight = await BackgroundAnalysisCoordinator.shared.inFlightTask(forMessageID: email.messageID) {
            isLoading = true
            let result = try? await inFlight.value
            isLoading = false
            if let result {
                analysis = result
                isFromCache = true
                syncTierIfMatchingCurrentProfile(modelUsed: result.modelUsed)
                triggerPriceLookup(analysis: result)
                return
            }
            if let cached = cacheStore.load(forMessageID: email.messageID) {
                analysis = cached
                isFromCache = true
                syncTierIfMatchingCurrentProfile(modelUsed: cached.modelUsed)
                triggerPriceLookup(analysis: cached)
                return
            }
        }

        if hasCredentials {
            await analyze(forceRefresh: false)
        }
    }

    func selectTier(_ tier: AIModelTier) {
        selectedTier = tier
        providerStore.setPreferredTier(tier)
    }

    func selectProfile(_ profile: AIProviderProfile) {
        providerStore.setActiveProfile(id: profile.id)
        refreshProviderState()
    }

    func analyze(forceRefresh: Bool) async {
        refreshProviderState()

        guard let apiKey = keychainStore.loadAPIKey(forProfileID: activeProfile.id), !apiKey.isEmpty else {
            errorMessage = AIServiceError.missingAPIKey(providerName: activeProfile.name).errorDescription
            return
        }
        if activeProfile.kind.requiresProjectID,
           activeProfile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            errorMessage = AIServiceError.missingProjectID.errorDescription
            return
        }

        if !forceRefresh, let cached = cacheStore.load(forMessageID: email.messageID) {
            analysis = cached
            isFromCache = true
            partialSnapshot = nil
            triggerPriceLookup(analysis: cached)
            return
        }

        isLoading = true
        errorMessage = nil
        partialSnapshot = nil
        defer { isLoading = false }

        let profileSnapshot = activeProfile
        let tierSnapshot = selectedTier

        do {
            let result = try await aiClient.analyzeEmail(
                email,
                profile: profileSnapshot,
                tier: tierSnapshot,
                apiKeyOverride: apiKey
            ) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.isLoading else { return }
                    self.partialSnapshot = snapshot
                }
            }
            try cacheStore.save(result, forMessageID: email.messageID)
            analysis = result
            partialSnapshot = nil
            isFromCache = false
            triggerPriceLookup(analysis: result)
        } catch {
            partialSnapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    func triggerPriceLookup(analysis: EmailAIAnalysis?) {
        priceLookupTask?.cancel()
        let currentEmail = email
        let lookupService = priceService
        isLoadingPrices = true
        priceLookupTask = Task { [weak self] in
            let groups = await lookupService.lookupRelatedPrices(
                for: currentEmail,
                analysis: analysis
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.priceGroups = groups
                self.isLoadingPrices = false
            }
        }
    }

    func cancelBackgroundTasks() {
        priceLookupTask?.cancel()
        priceLookupTask = nil
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

    // MARK: - Private

    private static func checkCredentials(profile: AIProviderProfile, keychainStore: KeychainStore) -> Bool {
        guard keychainStore.hasAPIKey(forProfileID: profile.id) else {
            return false
        }
        if profile.kind.requiresProjectID {
            return !profile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func syncTierIfMatchingCurrentProfile(modelUsed: String) {
        let normalized = modelUsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if normalized == activeProfile.deepModel {
            selectedTier = .deep
        } else if normalized == activeProfile.fastModel {
            selectedTier = .fast
        }
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
    @State private var showAttachmentFilingSheet = false
    @State private var filingFocusFilename: String?
    @State private var showRawLocalExtraction = false

    public init(email: ParsedEmailContext) {
        _vm = StateObject(wrappedValue: EmailAnalysisViewModel(email: email))
    }

    public var body: some View {
        Group {
            if showKeychainSheet {
                KeychainSettingsSheet(
                    onSavedKey: {
                        vm.refreshProviderState()
                        showKeychainSheet = false
                        Task {
                            await vm.analyze(forceRefresh: false)
                        }
                    },
                    onClose: {
                        vm.refreshProviderState()
                        showKeychainSheet = false
                    }
                )
            } else if showAttachmentFilingSheet {
                AttachmentFilingSheet(
                    email: vm.email,
                    analysis: vm.analysis,
                    preselectedFilename: filingFocusFilename,
                    onClose: {
                        showAttachmentFilingSheet = false
                    }
                )
            } else {
                VStack(spacing: 0) {
                    inspectorHeader
                    Divider().opacity(0.6)
                    contentBody
                    if let analysis = vm.analysis, !(vm.isLoading && vm.partialSnapshot?.isEmpty == false) {
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
        .onReceive(NotificationCenter.default.publisher(for: AIProviderStore.didChangeNotification)) { _ in
            vm.refreshProviderState()
        }
        .onDisappear {
            vm.cancelBackgroundTasks()
        }
    }

    // MARK: - Inspector Header

    private var activeFlagForHeader: (flag: MailFlagCategory, reason: String?) {
        if vm.isLoading,
           let partial = vm.partialSnapshot,
           let rawFlag = partial.suggestedFlag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let parsedFlag = MailFlagCategory(rawValue: rawFlag),
           parsedFlag != .none
        {
            return (parsedFlag, partial.flagReason)
        }
        if let analysis = vm.analysis {
            return (analysis.resolvedFlag, analysis.flagReason)
        }
        return (.none, nil)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(vm.email.subject.isEmpty ? "（无主题邮件）" : vm.email.subject)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    MailAIModelTierMenuButton(
                        selectedTier: Binding(
                            get: { vm.selectedTier },
                            set: { vm.selectTier($0) }
                        ),
                        activeProfileID: Binding(
                            get: { vm.activeProfile.id },
                            set: { id in
                                if let match = vm.profiles.first(where: { $0.id == id }) {
                                    vm.selectProfile(match)
                                }
                            }
                        ),
                        profiles: vm.profiles,
                        onSelectTier: { tier in
                            vm.selectTier(tier)
                        },
                        onSelectProfile: { profile in
                            vm.selectProfile(profile)
                        }
                    )

                    if let current = vm.analysis, current.modelUsed != vm.targetModelName {
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
                        helpText: "AI 服务商、工作区与自动化设置"
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

                let headerFlag = activeFlagForHeader
                if headerFlag.flag != .none {
                    MailFlagBadge(flag: headerFlag.flag, reason: headerFlag.reason)
                }

                Spacer(minLength: 8)

                if let toast = vm.copiedToast {
                    Text(toast)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else if vm.isLoading {
                    Text("流式生成中")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
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
        if vm.isLoading, let partial = vm.partialSnapshot, !partial.isEmpty {
            streamingScrollContent(partial)
        } else if vm.isLoading && vm.analysis == nil {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在摘要分析（\(vm.activeProfile.name) · \(vm.targetModelName)）…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("已提取正文 \(vm.email.plainBody.count) 字 · 引用 \(vm.email.quotedChain.count) 段 · 附件 \(vm.email.attachments.count) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 24)

                if !vm.priceGroups.isEmpty {
                    ScrollView {
                        historicalPricesSection(vm.priceGroups)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if !vm.hasCredentials && vm.analysis == nil {
            missingKeyPlaceholder
        } else if let error = vm.errorMessage, vm.analysis == nil {
            errorPlaceholder(error)
        } else if let analysis = vm.analysis {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if vm.isLoading {
                        streamingBanner
                    }

                    if let error = vm.errorMessage {
                        errorBanner(error)
                    }

                    summarySection(analysis)

                    if !analysis.todos.isEmpty {
                        todosSection(analysis.todos)
                    }

                    if !vm.priceGroups.isEmpty {
                        historicalPricesSection(vm.priceGroups)
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
                HStack(spacing: 8) {
                    Button("开始 AI 摘要分析") {
                        Task { await vm.analyze(forceRefresh: false) }
                    }
                    .buttonStyle(.borderedProminent)

                    if !vm.email.nonInlineAttachments.isEmpty {
                        Button("整理归档附件…") {
                            filingFocusFilename = nil
                            showAttachmentFilingSheet = true
                        }
                    }
                }
                if !vm.priceGroups.isEmpty {
                    ScrollView {
                        historicalPricesSection(vm.priceGroups)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var streamingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在流式接收 \(vm.activeProfile.name)（\(vm.targetModelName)）分析结果…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func streamingScrollContent(_ partial: PartialAnalysisSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                streamingBanner

                if partial.headline != nil || !partial.coreConclusions.isEmpty {
                    MailSectionContainer(title: "摘要结论（流式生成）", systemImage: "sparkles") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let headline = partial.headline, !headline.isEmpty {
                                MailHighlightedText(
                                    headline,
                                    fontSize: 13.5,
                                    baseWeight: .semibold,
                                    lineSpacing: 2
                                )
                            }

                            if !partial.coreConclusions.isEmpty {
                                Divider().opacity(0.6)

                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(partial.coreConclusions.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .top, spacing: 7) {
                                            Circle()
                                                .fill(Color.secondary.opacity(0.65))
                                                .frame(width: 4.5, height: 4.5)
                                                .padding(.top, 5.5)
                                            MailHighlightedText(item, fontSize: 12.5, lineSpacing: 2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if !vm.priceGroups.isEmpty {
                    historicalPricesSection(vm.priceGroups)
                }

                if let partialTranslation = partial.plainChineseTranslation,
                   !partialTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    translationSection(partialTranslation)
                }

                if !vm.email.attachments.isEmpty {
                    attachmentsSection(vm.email.attachments)
                }
            }
            .padding(12)
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
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("尚未配置 AI 服务商凭据")
                        .font(.system(size: 14, weight: .semibold))
                    Text("当前服务商「\(vm.activeProfile.name)」缺少 Keychain API Key\(vm.activeProfile.kind.requiresProjectID ? " 或 GCP Project ID" : "")。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    HStack(spacing: 8) {
                        Button("配置凭据") {
                            showKeychainSheet = true
                        }
                        .buttonStyle(.borderedProminent)

                        if !vm.email.nonInlineAttachments.isEmpty {
                            Button("整理归档附件…") {
                                filingFocusFilename = nil
                                showAttachmentFilingSheet = true
                            }
                        }
                    }
                }
                .padding(.top, 36)

                if !vm.priceGroups.isEmpty {
                    historicalPricesSection(vm.priceGroups)
                }
                if !vm.email.attachments.isEmpty {
                    attachmentsSection(vm.email.attachments)
                }
            }
            .padding()
        }
    }

    private func errorPlaceholder(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
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
                        if !vm.email.nonInlineAttachments.isEmpty {
                            Button("整理归档附件…") {
                                filingFocusFilename = nil
                                showAttachmentFilingSheet = true
                            }
                        }
                    }
                }
                .padding(.top, 28)

                if !vm.priceGroups.isEmpty {
                    historicalPricesSection(vm.priceGroups)
                }
                if !vm.email.attachments.isEmpty {
                    attachmentsSection(vm.email.attachments)
                }
            }
            .padding()
        }
    }

    // MARK: - Sections

    private func summarySection(_ analysis: EmailAIAnalysis) -> some View {
        MailSectionContainer(title: "摘要结论", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                MailHighlightedText(
                    analysis.headline,
                    fontSize: 13.5,
                    baseWeight: .semibold,
                    lineSpacing: 2
                )

                if !analysis.coreConclusions.isEmpty {
                    Divider().opacity(0.6)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(analysis.coreConclusions.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 7) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.65))
                                    .frame(width: 4.5, height: 4.5)
                                    .padding(.top, 5.5)
                                MailHighlightedText(item, fontSize: 12.5, lineSpacing: 2)
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
                            MailHighlightedText(todo.task, fontSize: 13)

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

    private func historicalPricesSection(_ groups: [SKUPriceComparisonGroup]) -> some View {
        MailSectionContainer(
            title: "历史报价参考 · Outlook KB",
            systemImage: "chart.line.uptrend.xyaxis",
            trailing: {
                Text("\(groups.count) 个型号")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { gIdx, group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(group.queriedSKU)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                            if let rangeLabel = formatPriceRange(group) {
                                Text(rangeLabel)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }

                            Spacer(minLength: 4)

                            if let hint = group.currentEmailPriceHint, !hint.isEmpty {
                                Text("本信：\(hint)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(group.records.enumerated()), id: \.element.id) { rIdx, record in
                                historicalPriceRow(record)
                                if rIdx < group.records.count - 1 {
                                    Divider().opacity(0.4)
                                }
                            }
                        }
                    }

                    if gIdx < groups.count - 1 {
                        Divider().opacity(0.6)
                    }
                }
            }
        }
    }

    private func historicalPriceRow(_ record: HistoricalPriceRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Text("\(record.currency) \(Self.formatUnitPrice(record.unitPrice))")
                        .font(.system(size: 12, weight: .semibold))
                        .textSelection(.enabled)

                    if !record.taxMode.isEmpty {
                        Text(record.taxMode)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.055))
                            .clipShape(Capsule())
                    }

                    if !record.priceTypeLabel.isEmpty {
                        Text(record.priceTypeLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.11))
                            .clipShape(Capsule())
                    }

                    Text(record.isExactSKUMatch ? "精确型号" : "同系列 · \(record.sku)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(record.isExactSKUMatch ? Color.green : Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((record.isExactSKUMatch ? Color.green : Color.orange).opacity(0.12))
                        .clipShape(Capsule())
                }

                let metaParts = [
                    record.customerOrg,
                    record.projectName,
                    record.quoteDateISO,
                    record.quantity.map { "数量 \(Self.formatUnitPrice($0))" }
                ]
                .compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            if let jumpURL = record.mailJumpURL {
                Button {
                    NSWorkspace.shared.open(jumpURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(record.subject.isEmpty ? "在 Apple Mail 中打开原报价邮件" : "打开原邮件：\(record.subject)")
            }
        }
        .padding(.vertical, 4.5)
    }

    private func formatPriceRange(_ group: SKUPriceComparisonGroup) -> String? {
        guard let minPrice = group.minUnitPrice, let maxPrice = group.maxUnitPrice else {
            return nil
        }
        let currencyPrefix = group.primaryCurrency.isEmpty ? "" : "\(group.primaryCurrency) "
        if abs(minPrice - maxPrice) < 0.0001 {
            return "\(currencyPrefix)\(Self.formatUnitPrice(minPrice))"
        }
        return "\(currencyPrefix)\(Self.formatUnitPrice(minPrice)) – \(Self.formatUnitPrice(maxPrice))"
    }

    private static func formatUnitPrice(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
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
            MailHighlightedText(translation, fontSize: 12.5, lineSpacing: 3)
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
                            MailHighlightedText(event.summary, fontSize: 12.5, lineSpacing: 1.5)
                        }
                    }
                }
            }
        }
    }

    private func attachmentsSection(_ attachments: [AttachmentSummary]) -> some View {
        MailSectionContainer(
            title: "附件 (\(attachments.count))",
            systemImage: "paperclip",
            trailing: {
                if !vm.email.nonInlineAttachments.isEmpty {
                    Button {
                        filingFocusFilename = nil
                        showAttachmentFilingSheet = true
                    } label: {
                        Label("整理归档…", systemImage: "folder.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .help("提取非内嵌附件并智能推荐归档目录（Dry-Run 预览后确认保存）")
                }
            }
        ) {
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
                        if !item.isInline {
                            Button {
                                filingFocusFilename = item.filename
                                showAttachmentFilingSheet = true
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("整理归档「\(item.filename)」")
                        }
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
