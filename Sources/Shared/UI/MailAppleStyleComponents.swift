import AppKit
import SwiftUI

/// Translucent macOS popover backdrop matching native Apple Mail extension popovers.
public struct MailVibrancyBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

/// Native Apple Mail 7-color flag pill (`紧急待回`, `等审批`, `跟报价`, etc.).
public struct MailFlagBadge: View {
    public let flag: MailFlagCategory
    public let reason: String?

    public init(flag: MailFlagCategory, reason: String? = nil) {
        self.flag = flag
        self.reason = reason
    }

    public var body: some View {
        if flag != .none {
            HStack(spacing: 4) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(flagColor)
                Text(flag.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(flagColor.opacity(0.12))
            .overlay(
                Capsule()
                    .stroke(flagColor.opacity(0.28), lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .help(reason?.isEmpty == false ? "\(flag.label)：\(reason!)" : flag.label)
        }
    }

    private var flagColor: Color {
        switch flag {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        case .none: return .secondary
        }
    }

    private var labelColor: Color {
        switch flag {
        case .yellow:
            return Color.primary.opacity(0.85)
        case .gray:
            return .secondary
        default:
            return flagColor
        }
    }
}

/// Understated macOS grouped inset section container.
public struct MailSectionContainer<Trailing: View, Content: View>: View {
    private let title: String
    private let systemImage: String
    private let trailing: Trailing
    private let content: Content

    public init(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing
            }

            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Compact native Mail-style model switcher menu chip (no emoji clutter).
public struct MailModelMenuButton: View {
    @Binding public var selection: GeminiModel
    public var onSelect: ((GeminiModel) -> Void)?

    public init(selection: Binding<GeminiModel>, onSelect: ((GeminiModel) -> Void)? = nil) {
        _selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        Menu {
            ForEach(GeminiModel.allCases) { model in
                Button {
                    selection = model
                    onSelect?(model)
                } label: {
                    HStack {
                        Text("\(compactLabel(for: model)) · \(model.subtitle)")
                        if model == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(compactLabel(for: selection))
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
        .help("切换 Gemini 模型")
    }

    private func compactLabel(for model: GeminiModel) -> String {
        switch model {
        case .flash38: return "Flash 3.8"
        case .carbon4: return "Carbon 4"
        }
    }
}

/// Borderless hover-highlighted toolbar icon button matching Apple Mail's header actions.
public struct MailIconActionButton: View {
    private let systemImage: String
    private let helpText: String
    private let isDisabled: Bool
    private let isActive: Bool
    private let action: () -> Void

    @State private var isHovered = false

    public init(
        systemImage: String,
        helpText: String,
        isDisabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.helpText = helpText
        self.isDisabled = isDisabled
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : (isDisabled ? Color.secondary.opacity(0.4) : Color.secondary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered && !isDisabled ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Natural-width wrapping layout for subtle macOS tag pills.
public struct MailWrapLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 5) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                maxRowWidth = max(maxRowWidth, currentX - horizontalSpacing)
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        maxRowWidth = max(maxRowWidth, max(0, currentX - horizontalSpacing))
        return CGSize(width: proposal.width ?? maxRowWidth, height: currentY + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
