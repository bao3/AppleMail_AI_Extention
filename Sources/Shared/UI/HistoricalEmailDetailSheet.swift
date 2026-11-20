import AppKit
import SwiftUI

/// In-panel read-only reader displaying original email headers, body, attachments,
/// and extracted price evidence snippets from `outlook.sqlite` without leaving Apple Mail's modal sheet.
public struct HistoricalEmailDetailSheet: View {
    private let record: HistoricalPriceRecord
    private let priceService: HistoricalPriceLookupService
    private let runtimeDBPath: String?
    private let onClose: () -> Void

    @State private var details: [HistoricalEmailDetail] = []
    @State private var selectedIndex: Int = 0
    @State private var isLoading: Bool = true
    @State private var isQuotedExpanded: Bool = false
    @State private var isAttachmentPreviewExpanded: Bool = false
    @State private var didCopySubject: Bool = false
    @State private var didTriggerMailOpen: Bool = false

    public init(
        record: HistoricalPriceRecord,
        priceService: HistoricalPriceLookupService = .shared,
        runtimeDBPath: String? = nil,
        onClose: @escaping () -> Void
    ) {
        self.record = record
        self.priceService = priceService
        self.runtimeDBPath = runtimeDBPath
        self.onClose = onClose
    }

    private var selectedDetail: HistoricalEmailDetail? {
        guard details.indices.contains(selectedIndex) else {
            return details.first
        }
        return details[selectedIndex]
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.6)

            if isLoading {
                loadingState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if details.count > 1 {
                            emailSwitcherBar
                        }
                        if let detail = selectedDetail {
                            mailHeaderCard(detail)
                            priceEvidenceCard(detail)
                            attachmentsAndBodyCard(detail)
                        } else {
                            fallbackSummaryCard
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 500)
        .background(MailVibrancyBackground())
        .task(id: record.id) {
            await loadDetails()
        }
    }

    // MARK: - Header & Switcher

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("历史报价原邮件与证据")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("\(record.sku) · \(record.currency) \(HistoricalPriceLookupService.formatUnitPrice(record.unitPrice))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("返回分析")
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("正在从本地 Outlook KB 读取原邮件与报价依据…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emailSwitcherBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("已合并 \(record.occurrenceCount) 封同价记录（展示最新 \(details.count) 封原邮件）")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(details.enumerated()), id: \.element.id) { idx, item in
                        let isSelected = idx == selectedIndex
                        Button {
                            selectedIndex = idx
                            isQuotedExpanded = false
                            isAttachmentPreviewExpanded = false
                        } label: {
                            HStack(spacing: 4) {
                                Text("#\(idx + 1)")
                                    .font(.system(size: 10, weight: .semibold))
                                if !item.dateISO.isEmpty {
                                    Text(shortDateText(item.dateISO))
                                        .font(.system(size: 10.5))
                                }
                                let actor = compactSenderOrCustomerLabel(item)
                                if !actor.isEmpty {
                                    Text("· \(actor)")
                                        .font(.system(size: 10.5))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private func mailHeaderCard(_ detail: HistoricalEmailDetail) -> some View {
        MailSectionContainer(
            title: "原邮件信息",
            systemImage: "envelope",
            trailing: {
                if !detail.subject.isEmpty {
                    Button {
                        copyTextToPasteboard(detail.subject)
                        didCopySubject = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            didCopySubject = false
                        }
                    } label: {
                        Text(didCopySubject ? "已复制" : "复制主题")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if !detail.subject.isEmpty {
                    Text(detail.subject)
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 3.5) {
                    if !detail.sender.isEmpty {
                        metadataLine(label: "发件人", value: detail.sender)
                    }
                    if !detail.recipients.isEmpty {
                        metadataLine(label: "收件人", value: detail.recipients)
                    }
                    if !detail.cc.isEmpty {
                        metadataLine(label: "抄送", value: detail.cc)
                    }
                    if !detail.dateISO.isEmpty {
                        metadataLine(label: "时间", value: detail.dateISO)
                    }
                    let sourceText = detail.folderPath.isEmpty
                        ? detail.sourceLabel
                        : "\(detail.sourceLabel) · \(detail.folderPath)"
                    if !sourceText.isEmpty {
                        metadataLine(label: "来源", value: sourceText)
                    }
                }

                if let jumpURL = detail.mailJumpURL ?? record.mailJumpURL {
                    Divider().opacity(0.45).padding(.vertical, 2)

                    HStack(spacing: 8) {
                        Button {
                            let config = NSWorkspace.OpenConfiguration()
                            config.activates = false
                            let mailAppURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
                            if FileManager.default.fileExists(atPath: mailAppURL.path) {
                                NSWorkspace.shared.open(
                                    [jumpURL],
                                    withApplicationAt: mailAppURL,
                                    configuration: config,
                                    completionHandler: nil
                                )
                            } else {
                                NSWorkspace.shared.open(jumpURL)
                            }
                            didTriggerMailOpen = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11))
                                Text("在 Mail 新窗口打开")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.11))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    if didTriggerMailOpen {
                        Text("已在后台唤起原邮件窗口；受 Apple Mail 模态窗口机制限制，关闭当前 AI 窗口后原邮件即会自动渲染正文。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func priceEvidenceCard(_ detail: HistoricalEmailDetail) -> some View {
        let evidences = detail.priceEvidences.isEmpty ? [fallbackEvidence(from: record)] : detail.priceEvidences
        return MailSectionContainer(title: "报价提取证据", systemImage: "tablecells") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(evidences.enumerated()), id: \.element.id) { idx, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text("\(item.currency) \(HistoricalPriceLookupService.formatUnitPrice(item.unitPrice))")
                                .font(.system(size: 12.5, weight: .semibold))
                                .textSelection(.enabled)

                            if !item.taxMode.isEmpty {
                                pillTag(item.taxMode, foreground: .secondary, background: Color.primary.opacity(0.06))
                            }
                            if !item.priceTypeLabel.isEmpty {
                                pillTag(item.priceTypeLabel, foreground: Color.accentColor, background: Color.accentColor.opacity(0.11))
                            }
                            if !item.sourceKindLabel.isEmpty {
                                pillTag(item.sourceKindLabel, foreground: .orange, background: Color.orange.opacity(0.12))
                            }
                        }

                        let meta = [
                            item.sku,
                            item.customerOrg,
                            item.projectName,
                            item.quantity.map { "数量 \(HistoricalPriceLookupService.formatUnitPrice($0))" }
                        ]
                        .compactMap { $0 }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                        if !meta.isEmpty {
                            Text(meta.joined(separator: " · "))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if !item.evidenceSnippet.isEmpty {
                            Text(item.evidenceSnippet)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }

                    if idx < evidences.count - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }
        }
    }

    private func attachmentsAndBodyCard(_ detail: HistoricalEmailDetail) -> some View {
        let previewableAttachments = detail.attachments.filter { !$0.textPreview.isEmpty }
        let shouldShowAttachmentPreviews = detail.bodyLatest.count < 120 && !previewableAttachments.isEmpty

        return MailSectionContainer(title: "邮件正文与附件", systemImage: "doc.plaintext") {
            VStack(alignment: .leading, spacing: 8) {
                if !detail.attachments.isEmpty {
                    MailWrapLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(detail.attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(attachment.filename)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                if attachment.sizeBytes > 0 {
                                    Text("(\(ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file)))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(Color.primary.opacity(0.055))
                            .clipShape(Capsule())
                        }
                    }
                }

                if shouldShowAttachmentPreviews {
                    DisclosureGroup("查看附件文本摘录（\(previewableAttachments.count) 个）", isExpanded: $isAttachmentPreviewExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(previewableAttachments) { att in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(att.filename)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(att.textPreview)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.88))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                if !detail.attachments.isEmpty {
                    Divider().opacity(0.45)
                }

                if detail.bodyLatest.isEmpty {
                    Text("（原邮件无纯文本正文，核心数据位于上方附件表格或 HTML 表格中）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(detail.bodyLatest)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !detail.bodyQuoted.isEmpty {
                    Divider().opacity(0.45)
                    DisclosureGroup("展开历史引用对话", isExpanded: $isQuotedExpanded) {
                        Text(detail.bodyQuoted)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fallbackSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MailSectionContainer(title: "报价记录摘要（未从本地缓存定位完整正文）", systemImage: "envelope.badge") {
                VStack(alignment: .leading, spacing: 5) {
                    if !record.subject.isEmpty {
                        Text(record.subject)
                            .font(.system(size: 12.5, weight: .semibold))
                            .textSelection(.enabled)
                    }
                    if !record.customerOrg.isEmpty {
                        metadataLine(label: "客户", value: record.customerOrg)
                    }
                    if !record.projectName.isEmpty {
                        metadataLine(label: "项目", value: record.projectName)
                    }
                    if !record.quoteDateISO.isEmpty {
                        metadataLine(label: "日期", value: record.quoteDateISO)
                    }
                }
            }

            if !record.evidenceSnippet.isEmpty {
                MailSectionContainer(title: "报价提取证据", systemImage: "tablecells") {
                    Text(record.evidenceSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadDetails() async {
        isLoading = true
        let loaded = await priceService.loadHistoricalEmailDetails(
            for: record,
            runtimeDBPath: runtimeDBPath
        )
        details = loaded
        selectedIndex = 0
        isQuotedExpanded = false
        isAttachmentPreviewExpanded = false
        isLoading = false
    }

    private func fallbackEvidence(from record: HistoricalPriceRecord) -> HistoricalEmailPriceEvidence {
        HistoricalEmailPriceEvidence(
            id: record.id,
            sku: record.sku,
            currency: record.currency,
            unitPrice: record.unitPrice,
            quantity: record.quantity,
            priceType: record.priceType,
            priceTypeLabel: record.priceTypeLabel,
            taxMode: record.taxMode,
            customerOrg: record.customerOrg,
            projectName: record.projectName,
            sourceKind: "",
            evidenceSnippet: record.evidenceSnippet
        )
    }

    private func metadataLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label)：")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pillTag(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background)
            .clipShape(Capsule())
    }

    private func shortDateText(_ raw: String) -> String {
        String(raw.prefix(10))
    }

    private func compactSenderOrCustomerLabel(_ detail: HistoricalEmailDetail) -> String {
        let candidate = detail.customersOrgs.isEmpty ? detail.sender : detail.customersOrgs
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if let angleStart = trimmed.firstIndex(of: "<") {
            let display = String(trimmed[..<angleStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !display.isEmpty {
                return display.count > 14 ? String(display.prefix(13)) + "…" : display
            }
        }
        return trimmed.count > 14 ? String(trimmed.prefix(13)) + "…" : trimmed
    }

    private func copyTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
