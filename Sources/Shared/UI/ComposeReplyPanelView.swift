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
    @Published var selectedModel: GeminiModel
    @Published var tone: ComposeReplyTone = .professional
    @Published var userIntent: String = ""
    @Published var manualOriginalContext: String = ""
    @Published var selectedTab: ComposeDraftTab = .bilingual
    @Published var draft: ComposeReplyDraft?
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var hasAPIKey: Bool
    @Published var copiedToast: String?

    let originalEmail: ParsedEmailContext?
    let draftSubject: String
    let recipients: [String]

    private let keychainStore: KeychainStore
    private let client: VertexGeminiClient

    init(
        originalEmail: ParsedEmailContext?,
        draftSubject: String,
        recipients: [String],
        keychainStore: KeychainStore = .shared,
        client: VertexGeminiClient = .shared
    ) {
        self.originalEmail = originalEmail
        self.draftSubject = draftSubject
        self.recipients = recipients
        self.keychainStore = keychainStore
        self.client = client
        self.selectedModel = keychainStore.loadPreferredModel()
        self.hasAPIKey = keychainStore.hasAPIKey()
    }

    func refreshKeyStatus() {
        hasAPIKey = keychainStore.hasAPIKey()
        selectedModel = keychainStore.loadPreferredModel()
    }

    func selectModel(_ model: GeminiModel) {
        selectedModel = model
        keychainStore.savePreferredModel(model)
    }

    func applyQuickIntent(_ template: String) {
        if userIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userIntent = template
        } else {
            userIntent += "\n" + template
        }
    }

    func generate() async {
        hasAPIKey = keychainStore.hasAPIKey()
        guard let apiKey = keychainStore.loadAPIKey() else {
            errorMessage = VertexGeminiError.missingAPIKey.errorDescription
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
            draft = try await client.generateReplyDraft(
                originalEmail: contextToUse,
                draftSubject: draftSubject,
                recipients: recipients,
                userIntent: trimmedIntent,
                tone: tone.rawValue,
                model: selectedModel,
                apiKey: apiKey
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyDraftText(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let toast = "已复制\(label)（在写信框按 ⌘V 粘贴）"
        copiedToast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if self.copiedToast == toast {
                self.copiedToast = nil
            }
        }
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
                        vm.refreshKeyStatus()
                        showKeychainSheet = false
                    },
                    onClose: {
                        vm.refreshKeyStatus()
                        showKeychainSheet = false
                    }
                )
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            originalContextSection
                            intentComposerSection

                            if let error = vm.errorMessage {
                                Text("⚠️ \(error)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.red.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            if let draft = vm.draft {
                                draftOutputSection(draft)
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            vm.refreshKeyStatus()
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI 双语回复助手", systemImage: "square.and.pencil")
                    .font(.headline)
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
                Button {
                    showKeychainSheet = true
                } label: {
                    Label("Key", systemImage: "key.fill")
                }
                .controlSize(.small)
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
                .frame(maxWidth: 220)

                Picker("语气", selection: $vm.tone) {
                    ForEach(ComposeReplyTone.allCases) { tone in
                        Text(tone.rawValue).tag(tone)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    @ViewBuilder
    private var originalContextSection: some View {
        if let original = vm.originalEmail {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "envelope.open.fill")
                        .foregroundStyle(.blue)
                    Text("已自动读取原信上下文")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if !original.attachments.isEmpty {
                        Text("附件 \(original.attachments.count) 个")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("主题：\(original.subject.isEmpty ? "(无主题)" : original.subject)")
                    .font(.caption)
                    .lineLimit(1)
                if !original.from.isEmpty {
                    Text("原发件人：\(original.from)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !original.plainBody.isEmpty {
                    Text(original.plainBody)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("未检测到引用原信（新建邮件或纯文本草稿），可选粘贴对方来信摘要：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.manualOriginalContext)
                    .font(.caption)
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
        }
    }

    private var intentComposerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入你想表达的回复要点（支持中英文混输）：")
                .font(.subheadline.weight(.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickIntents, id: \.self) { snippet in
                        Button(snippet) {
                            vm.applyQuickIntent(snippet)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }

            TextEditor(text: $vm.userIntent)
                .font(.callout)
                .frame(height: 82)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )

            HStack {
                Text("MailKit 安全限制不允许扩展直接篡改编辑器正文，生成后可一键复制粘贴。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.generate() }
                } label: {
                    HStack(spacing: 5) {
                        if vm.isGenerating {
                            ProgressView().controlSize(.small)
                        }
                        Text(vm.isGenerating ? "生成中…" : "生成双语回复草稿")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGenerating)
            }
        }
    }

    private func draftOutputSection(_ draft: ComposeReplyDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack {
                Text("建议主题：\(draft.suggestedSubject)")
                    .font(.caption.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Button("复制主题") {
                    vm.copyDraftText(draft.suggestedSubject, label: "主题")
                }
                .controlSize(.small)
            }

            Picker("显示格式", selection: $vm.selectedTab) {
                ForEach(ComposeDraftTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            let activeText: String = switch vm.selectedTab {
            case .bilingual: draft.bilingualCombinedDraft
            case .english: draft.englishDraft
            case .chinese: draft.chineseDraft
            }

            Text(activeText)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            HStack {
                Button("复制当前版本") {
                    vm.copyDraftText(activeText, label: vm.selectedTab.rawValue)
                }
                .buttonStyle(.borderedProminent)

                Button("仅复制英文") {
                    vm.copyDraftText(draft.englishDraft, label: "英文正文")
                }

                Button("仅复制中文") {
                    vm.copyDraftText(draft.chineseDraft, label: "中文正文")
                }
                Spacer()
                Text(draft.modelUsed)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
