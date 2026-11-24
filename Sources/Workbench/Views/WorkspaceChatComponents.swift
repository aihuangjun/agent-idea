import DesignSystem
import SwiftUI

// KBReader Sources/AIChat/UI/ChatPanelView.swift: header controls and transcript bubbles.
struct NewSessionButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("新会话").font(.caption.weight(.medium))
            }
            .foregroundStyle(isEnabled ? Color.primary : WorkspaceChatPalette.secondaryText.opacity(0.6))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hovering && isEnabled ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkspaceChatPalette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip("为当前项目新建会话（⌥⌘I）")
    }
}

struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WorkspaceChatPalette.secondaryText)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip(help)
    }
}

enum Bubble {
    static let corner: CGFloat = 14
    static let padding: CGFloat = 12
    static let avatar: CGFloat = 22
}
struct BubbleShape: Shape {
    enum Tail { case leading, trailing }
    let tail: Tail

    func path(in rect: CGRect) -> Path {
        let big = Bubble.corner
        let small: CGFloat = 4
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: tail == .leading ? small : big,
            bottomLeading: big,
            bottomTrailing: big,
            topTrailing: tail == .trailing ? small : big
        ))
    }
}

struct AssistantAvatar: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Bubble.avatar, height: Bubble.avatar)
            .background(WorkspaceChatPalette.accent.gradient, in: Circle())
            .padding(.top, 2)
            .accessibilityHidden(true)
    }
}
struct ActivityRow<Detail: View>: View {
    let symbol: String
    let title: String
    let summary: String
    let monospacedSummary: Bool
    let isRunning: Bool
    let failed: Bool
    let detail: () -> Detail
    @State private var expanded: Bool
    @State private var hovering = false

    init(
        symbol: String, title: String, summary: String, monospacedSummary: Bool = false,
        isRunning: Bool = false, failed: Bool = false, initiallyExpanded: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.symbol = symbol
        self.title = title
        self.summary = summary
        self.monospacedSummary = monospacedSummary
        self.isRunning = isRunning
        self.failed = failed
        self.detail = detail
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WorkspaceChatPalette.secondaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(failed ? Theme.warning : WorkspaceChatPalette.secondaryText)
                        .frame(width: 14)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize()
                    Text(summary)
                        .font(monospacedSummary ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(WorkspaceChatPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isRunning {
                        ProgressView().controlSize(.mini)
                    } else if failed {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .toolTip(expanded ? "收起" : "展开")
            if expanded {
                Divider().padding(.horizontal, 8)
                detail()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(Color.primary.opacity(hovering ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onChange(of: failed) { _, failed in if failed { expanded = true } }
    }
}

/// 展开后的长文本：内容多高就多高，封顶之后在框里滚。
struct ActivityDetailText: View {
    let text: String
    var monospaced = false

    var body: some View {
        ScrollView {
            // 工具输出原样（等宽）；推理摘要里常带 `**小标题**`，按行内 Markdown 画，不露星号。
            Text(monospaced ? AttributedString(text) : ChatMarkdownText.attributed(text))
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(monospaced ? Color.primary : WorkspaceChatPalette.secondaryText)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
    }
}
