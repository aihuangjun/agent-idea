import AppKit
import Core
import SwiftUI

/// 面板之间可拖动的竖向分隔条。拖动改的是左侧面板的宽度。
public struct ResizeHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var isHovering = false
    @State private var startWidth: CGFloat?

    public init(width: Binding<CGFloat>, range: ClosedRange<CGFloat>) {
        _width = width
        self.range = range
    }

    public var body: some View {
        Rectangle()
            .fill(isHovering ? Theme.accent.opacity(0.6) : Theme.border)
            .frame(width: 1)
            .overlay(
                // 命中区域比可见的线宽得多，否则要瞄得很准才抓得住
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                width = min(range.upperBound, max(range.lowerBound, (startWidth ?? width) + value.translation.width))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            )
    }
}

/// 横着的分隔条：拖它改下方面板的高度（底部「运行」窗口），往上拖变高。命中区域同样比线宽得多。
public struct HeightResizeHandle: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var isHovering = false
    @State private var startHeight: CGFloat?

    public init(height: Binding<CGFloat>, range: ClosedRange<CGFloat>) {
        _height = height
        self.range = range
    }

    public var body: some View {
        Rectangle()
            .fill(isHovering ? Theme.accent.opacity(0.6) : Theme.border)
            .frame(height: 1)
            .overlay(
                Color.clear.frame(height: 9).contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startHeight == nil { startHeight = height }
                                height = min(range.upperBound, max(range.lowerBound, (startHeight ?? height) - value.translation.height))
                            }
                            .onEnded { _ in startHeight = nil }
                    )
            )
    }
}

/// 悬停提示（AppKit 的 `NSView.toolTip`）。
///
/// SwiftUI 的 `.help()` 在我们这些 `.buttonStyle(.plain)` + 自定义 label 的按钮上不落地：
/// 挂上去之后 NSView 层级里根本没有 `toolTip`，鼠标停多久都不出提示（`IconButtonTests` 守着这一点）。
/// 这里往按钮背景塞一个铺满的空 NSView，只负责提示：`hitTest` 一律返回 nil，点击与悬停底色照旧归上面的
/// SwiftUI 按钮（tooltip 走的是窗口的 tracking rect，不经过 hitTest）。
public struct ToolTip: NSViewRepresentable {
    let text: String

    public init(_ text: String) { self.text = text }

    public func makeNSView(context: Context) -> NSView {
        let view = PassThrough()
        view.toolTip = text
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }

    final class PassThrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

public extension View {
    /// 悬停提示。用它，别用 SwiftUI 的 `.help()`——那个在这套自定义按钮上不出提示。
    func toolTip(_ text: String) -> some View { background(ToolTip(text)) }
}

/// 工具条 / 标签上的小图标按钮：悬停出底色，无边框，鼠标停一下出提示。
public struct IconButton: View {
    let systemName: String
    let help: String
    let isActive: Bool
    let size: CGFloat
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    public init(_ systemName: String, help: String, isActive: Bool = false, size: CGFloat = 26, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.isActive = isActive
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(isActive ? Theme.text : Theme.secondaryText)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? Theme.selection.opacity(0.9) : (isHovering && isEnabled ? Theme.hover : .clear))
                )
                // `.disabled` 时明确灰掉：plain 样式对自定义 label 不一定有禁用外观
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .toolTip(help)
    }
}

/// 面板上的主按钮（提交、提交并推送）：IntelliJ 蓝填充，悬停提亮、按下压暗、禁用时整体变淡。
///
/// 不用系统的 `.borderedProminent`：它只给「默认按钮」上色，同一行里第二个按钮会是灰的
/// （0.7.0 之前提交面板就是「提交」蓝、「提交并推送」灰，看着像两级功能）。
public struct AccentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    /// 不能叫 `Body`：那是 `ButtonStyle` 自己的关联类型，重名会让 `makeBody` 的返回类型自指。
    private struct Content: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.55))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent.opacity(isEnabled ? 1 : 0.35))
                        // 悬停提亮、按下压暗，都叠在同一块蓝上，两个按钮的反馈完全一致
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(configuration.isPressed ? Color.black.opacity(0.18)
                                      : (isHovering && isEnabled ? Color.white.opacity(0.14) : Color.clear))
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { isHovering = $0 }
        }
    }
}

/// 一个小小的计数角标。
public struct CountBadge: View {
    let count: Int

    public init(_ count: Int) {
        self.count = count
    }

    public var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(Theme.accent))
        }
    }
}

/// 文件图标：按 Core 识别出的语言给一个 SF Symbol 和颜色。IDEA 那套图标是私有的，这里用系统符号近似。
///
/// 以 `Language.name` 为键，扩展名的事实源只有 Core 的那一张表；颜色一律引用 `Theme`。
public enum FileIcon {
    public struct Descriptor: Equatable {
        public let systemName: String
        public let color: Color

        public init(systemName: String, color: Color) {
            self.systemName = systemName
            self.color = color
        }
    }

    public static let folder = Descriptor(systemName: "folder.fill", color: Theme.folderIcon)

    public static func file(named name: String) -> Descriptor {
        let lower = name.lowercased()
        switch FileCategory.forFile(named: name) {
        case .image: return Descriptor(systemName: "photo", color: Theme.iconPurple)
        case .pdf: return Descriptor(systemName: "doc.text.image", color: Theme.danger)
        case .markdown: return Descriptor(systemName: "doc.richtext", color: Theme.vcsModified)
        case .code(let language): return byLanguage[language.name] ?? fallback(for: lower)
        }
    }

    private static let byLanguage: [String: Descriptor] = [
        "Swift": Descriptor(systemName: "swift", color: Theme.iconOrange),
        "JSON": Descriptor(systemName: "curlybraces", color: Theme.iconAmber),
        "YAML": Descriptor(systemName: "list.bullet.indent", color: Theme.iconPurple),
        "TOML": Descriptor(systemName: "list.bullet.indent", color: Theme.iconPurple),
        "INI": Descriptor(systemName: "list.bullet.indent", color: Theme.iconPurple),
        "Env": Descriptor(systemName: "list.bullet.indent", color: Theme.iconPurple),
        "XML": Descriptor(systemName: "chevron.left.forwardslash.chevron.right", color: Theme.iconYellow),
        "HTML": Descriptor(systemName: "globe", color: Theme.iconOrange),
        "CSS": Descriptor(systemName: "paintpalette", color: Theme.iconBlue),
        "SCSS": Descriptor(systemName: "paintpalette", color: Theme.iconBlue),
        "Less": Descriptor(systemName: "paintpalette", color: Theme.iconBlue),
        "JavaScript": Descriptor(systemName: "j.square", color: Theme.warning),
        "TypeScript": Descriptor(systemName: "t.square", color: Theme.iconBlue),
        "Python": Descriptor(systemName: "p.square", color: Theme.iconBlue),
        "Java": Descriptor(systemName: "cup.and.saucer", color: Theme.iconOrange),
        "Kotlin": Descriptor(systemName: "cup.and.saucer", color: Theme.iconOrange),
        "Scala": Descriptor(systemName: "cup.and.saucer", color: Theme.iconOrange),
        "Go": Descriptor(systemName: "g.square", color: Theme.iconTeal),
        "Rust": Descriptor(systemName: "gearshape", color: Theme.iconOrange),
        "C": Descriptor(systemName: "c.square", color: Theme.vcsModified),
        "C++": Descriptor(systemName: "c.square", color: Theme.vcsModified),
        "C#": Descriptor(systemName: "c.square", color: Theme.vcsModified),
        "Objective-C": Descriptor(systemName: "c.square", color: Theme.vcsModified),
        "Objective-C++": Descriptor(systemName: "c.square", color: Theme.vcsModified),
        "Shell": Descriptor(systemName: "terminal", color: Theme.success),
        "PowerShell": Descriptor(systemName: "terminal", color: Theme.success),
        "SQL": Descriptor(systemName: "cylinder", color: Theme.vcsModified),
        "Diff": Descriptor(systemName: "plus.forwardslash.minus", color: Theme.success),
        "Dockerfile": Descriptor(systemName: "shippingbox", color: Theme.iconBlue),
        "Makefile": Descriptor(systemName: "hammer", color: Theme.secondaryText),
        "CMake": Descriptor(systemName: "hammer", color: Theme.secondaryText),
        "Ignore": Descriptor(systemName: "arrow.triangle.branch", color: Theme.iconOrange),
        "Git": Descriptor(systemName: "arrow.triangle.branch", color: Theme.iconOrange),
    ]

    /// 语言表里没有的：按几种常见的非代码文件给图标，其余是一张白纸。
    private static func fallback(for lower: String) -> Descriptor {
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "zip", "gz", "tar", "dmg", "jar", "7z", "rar", "icns":
            return Descriptor(systemName: "doc.zipper", color: Theme.secondaryText)
        case "lock":
            return Descriptor(systemName: "lock.doc", color: Theme.secondaryText)
        case "txt", "log", "text", "csv", "tsv":
            return Descriptor(systemName: "doc.text", color: Theme.secondaryText)
        default:
            break
        }
        if lower.hasPrefix("license") { return Descriptor(systemName: "checkmark.seal", color: Theme.secondaryText) }
        if lower.hasPrefix(".") { return Descriptor(systemName: "gearshape", color: Theme.secondaryText) }
        return Descriptor(systemName: "doc", color: Theme.secondaryText)
    }
}
