import AppKit
import SwiftUI

public enum ComposeReplyTone: String, CaseIterable, Identifiable, Sendable {
    case professional = "商务专业"
    case concise = "简洁直接"
    case warm = "温和礼貌"

    public var id: String { rawValue }
}

public enum ComposeDraftTab: String, CaseIterable, Identifiable {
    case bilingual = "中英双语"
    case english = "英文正文"
    case chinese = "中文正文"

    public var id: String { rawValue }
}

@MainActor
final class ComposeReplyViewModel: ObservableObject {
    @Published var activeProfile: AIProviderProfile
    @Published var profiles: [AIProviderProfile]
    @Published var selectedTier: AIModelTier
    @Published var tone: ComposeReplyTone = .professional
    @Published var userIntent: String = ""
    @Published var manualOriginalContext: String = ""
    @Published var selectedTab: ComposeDraftTab = .bilingual
    @Published var draft: ComposeReplyDraft?
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var hasCredentials: Bool
    @Published var copiedToast: String?

    let originalEmail: ParsedEmailContext?
    let draftSubject: String
    let recipients: [String]

    private let keychainStore: KeychainStore
    private let providerStore: AIProviderStore
    private let aiClient: AIServiceClient

    init(
        originalEmail: ParsedEmailContext?,
        draftSubject: String,
        recipients: [String],
        keychainStore: KeychainStore = .shared,
        providerStore: AIProviderStore = .shared,
        aiClient: AIServiceClient = .shared
    ) {
        self.originalEmail = originalEmail
        self.draftSubject = draftSubject
        self.recipients = recipients
        self.keychainStore = keychainStore
        self.providerStore = providerStore
        self.aiClient = aiClient

        let currentProfile = providerStore.activeProfile
        self.activeProfile = currentProfile
        self.profiles = providerStore.profiles
        self.selectedTier = providerStore.preferredTier
        self.hasCredentials = Self.checkCredentials(profile: currentProfile, keychainStore: keychainStore)
    }

    func refreshProviderState() {
        let currentProfile = providerStore.activeProfile
        activeProfile = currentProfile
        profiles = providerStore.profiles
        selectedTier = providerStore.preferredTier
        hasCredentials = Self.checkCredentials(profile: currentProfile, keychainStore: keychainStore)
    }

    func selectTier(_ tier: AIModelTier) {
        selectedTier = tier
        providerStore.setPreferredTier(tier)
    }

    func selectProfile(_ profile: AIProviderProfile) {
        providerStore.setActiveProfile(id: profile.id)
        refreshProviderState()
    }

    func applyQuickIntent(_ template: String) {
        if userIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userIntent = template
        } else {
            userIntent += "\n" + template
        }
    }

    func generate() async {
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

        let trimmedIntent = userIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIntent.isEmpty else {
            errorMessage = "请先输入希望回复的核心要点或选择快捷模板。"
            return
        }

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        let contextToUse: ParsedEmailContext?
        if let originalEmail {
            contextToUse = originalEmail
        } else if !manualOriginalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextToUse = ParsedEmailContext(
                messageID: "manual-compose-context",
                subject: draftSubject,
                from: "",
                to: recipients,
                cc: [],
                dateString: "",
                inReplyTo: nil,
                references: [],
                plainBody: manualOriginalContext,
                quotedChain: [],
                attachments: []
            )
        } else {
            contextToUse = nil
        }

        do {
            draft = try await aiClient.generateReplyDraft(
                originalEmail: contextToUse,
                draftSubject: draftSubject,
                recipients: recipients,
                userIntent: trimmedIntent,
                tone: tone.rawValue,
                profile: activeProfile,
                tier: selectedTier,
                apiKeyOverride: apiKey
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyDraftText(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let toast = "已复制\(label)（在写信框按 ⌘V）"
        copiedToast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if self.copiedToast == toast {
                self.copiedToast = nil
            }
        }
    }

    private static func checkCredentials(profile: AIProviderProfile, keychainStore: KeychainStore) -> Bool {
        guard keychainStore.hasAPIKey(forProfileID: profile.id) else {
            return false
        }
        if profile.kind.requiresProjectID {
            return !profile.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

public struct ComposeReplyPanelView: View {
    @StateObject private var vm: ComposeReplyViewModel
    @State private var showKeychainSheet = false

    private let quickIntents = [
        "确认收到报价，请补充 FOB/CIF 条款及交期",
        "接受技术方案，安排本周五前发测试样品",
        "价格偏高，申请按 500 台阶梯量重新核算单价",
        "告知客户已内部立项评估，将在 2 个工作日内正式答复"
    ]

    public init(originalEmail: ParsedEmailContext?, draftSubject: String, recipients: [String]) {
        _vm = StateObject(wrappedValue: ComposeReplyViewModel(
            originalEmail: originalEmail,
            draftSubject: draftSubject,
            recipients: recipients
        ))
    }

    public var body: some View {
        Group {
            if showKeychainSheet {
                KeychainSettingsSheet(
                    onSavedKey: {
                        vm.refreshProviderState()
                        showKeychainSheet = false
                    },
                    onClose: {
                        vm.refreshProviderState()
                        showKeychainSheet = false
                    }
                )
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider().opacity(0.6)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            originalContextSection
                            intentComposerSection

                            if let error = vm.errorMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11.5))
                                    Text(error)
                                        .font(.system(size: 11.5))
                                }
                                .foregroundStyle(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }

                            if let draft = vm.draft {
                                draftOutputSection(draft)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(MailVibrancyBackground())
        .task {
            vm.refreshProviderState()
        }
        .onReceive(NotificationCenter.default.publisher(for: AIProviderStore.didChangeNotification)) { _ in
            vm.refreshProviderState()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("AI 双语回复")
                .font(.system(size: 13.5, weight: .semibold))

            if let toast = vm.copiedToast {
                Text(toast)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

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

            Menu {
                ForEach(ComposeReplyTone.allCases) { tone in
                    Button {
                        vm.tone = tone
                    } label: {
                        HStack {
                            Text(tone.rawValue)
                            if vm.tone == tone {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(vm.tone.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .overlay(
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("选择回复语气")

            MailIconActionButton(systemImage: "gearshape", helpText: "AI 服务商与自动化设置") {
                showKeychainSheet = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var originalContextSection: some View {
        if let original = vm.originalEmail {
            MailSectionContainer(
                title: "原信上下文",
                systemImage: "envelope.open",
                trailing: {
                    if !original.attachments.isEmpty {
                        Text("附件 \(original.attachments.count)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(original.subject.isEmpty ? "（无主题）" : original.subject)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !original.from.isEmpty {
                        Text(original.from)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !original.plainBody.isEmpty {
                        Text(original.plainBody)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        } else {
            MailSectionContainer(title: "原信摘要（可选）", systemImage: "doc.text") {
                TextEditor(text: $vm.manualOriginalContext)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 56)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var intentComposerSection: some View {
        MailSectionContainer(title: "回复要点", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickIntents, id: \.self) { snippet in
                            Button(snippet) {
                                vm.applyQuickIntent(snippet)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.055))
                            .overlay(
                                Capsule()
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                            )
                            .clipShape(Capsule())
                        }
                    }
                }

                TextEditor(text: $vm.userIntent)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 82)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                HStack {
                    Text("生成后点击复制即可 ⌘V 粘贴到正文")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await vm.generate() }
                    } label: {
                        HStack(spacing: 5) {
                            if vm.isGenerating {
                                ProgressView().controlSize(.small)
                            }
                            Text(vm.isGenerating ? "生成中…" : "生成双语草稿")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.isGenerating)
                }
            }
        }
    }

    private func draftOutputSection(_ draft: ComposeReplyDraft) -> some View {
        let activeText: String = switch vm.selectedTab {
        case .bilingual: draft.bilingualCombinedDraft
        case .english: draft.englishDraft
        case .chinese: draft.chineseDraft
        }

        return MailSectionContainer(
            title: "生成草稿",
            systemImage: "sparkles",
            trailing: {
                Text(draft.modelUsed)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("主题：\(draft.suggestedSubject)")
                        .font(.system(size: 12, weight: .medium))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer()
                    Button("复制主题") {
                        vm.copyDraftText(draft.suggestedSubject, label: "主题")
                    }
                    .controlSize(.mini)
                }

                Picker("显示格式", selection: $vm.selectedTab) {
                    ForEach(ComposeDraftTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                Text(activeText)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                HStack(spacing: 8) {
                    Button("复制当前版本") {
                        vm.copyDraftText(activeText, label: vm.selectedTab.rawValue)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("仅英文") {
                        vm.copyDraftText(draft.englishDraft, label: "英文正文")
                    }
                    .controlSize(.small)

                    Button("仅中文") {
                        vm.copyDraftText(draft.chineseDraft, label: "中文正文")
                    }
                    .controlSize(.small)

                    Spacer()
                }
            }
        }
    }
}
