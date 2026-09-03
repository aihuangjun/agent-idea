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

/// 工具条 / 标签上的小图标按钮：悬停出底色，无边框。
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
        .help(help)
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
        "Go": Descriptor(systemName: "g.square", color: Theme.vcsRenamed),
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
