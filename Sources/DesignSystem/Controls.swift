import AppKit
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
                        .fill(isActive ? Theme.selection.opacity(0.9) : (isHovering ? Theme.hover : .clear))
                )
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

/// 文件图标：按名字给一个 SF Symbol 和颜色。IDEA 那套图标是私有的，这里用系统符号近似。
public enum FileIcon {
    public struct Descriptor: Equatable {
        public let systemName: String
        public let color: Color

        public init(systemName: String, color: Color) {
            self.systemName = systemName
            self.color = color
        }
    }

    public static func folder(isExpanded: Bool) -> Descriptor {
        Descriptor(systemName: isExpanded ? "folder.fill" : "folder.fill", color: Color(hex: 0x8C9CB8))
    }

    public static func file(named name: String) -> Descriptor {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "swift": return Descriptor(systemName: "swift", color: Color(hex: 0xF05138))
        case "md", "markdown", "mdx": return Descriptor(systemName: "doc.richtext", color: Color(hex: 0x6C9EF8))
        case "json", "json5", "jsonc": return Descriptor(systemName: "curlybraces", color: Color(hex: 0xE8C08D))
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "env": return Descriptor(systemName: "list.bullet.indent", color: Color(hex: 0xC77DBB))
        case "xml", "plist", "xib", "storyboard", "svg", "entitlements": return Descriptor(systemName: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xD5B778))
        case "html", "htm", "vue", "svelte": return Descriptor(systemName: "globe", color: Color(hex: 0xE8A25E))
        case "css", "scss", "sass", "less": return Descriptor(systemName: "paintpalette", color: Color(hex: 0x56A8F5))
        case "js", "mjs", "cjs", "jsx": return Descriptor(systemName: "j.square", color: Color(hex: 0xF2C55C))
        case "ts", "tsx", "mts", "cts": return Descriptor(systemName: "t.square", color: Color(hex: 0x3B8EEA))
        case "py", "pyi": return Descriptor(systemName: "p.square", color: Color(hex: 0x4B8BBE))
        case "java", "kt", "kts", "scala": return Descriptor(systemName: "cup.and.saucer", color: Color(hex: 0xE8A25E))
        case "go": return Descriptor(systemName: "g.square", color: Color(hex: 0x29BEB0))
        case "rs": return Descriptor(systemName: "gearshape", color: Color(hex: 0xDEA584))
        case "c", "h", "cpp", "cc", "hpp", "m", "mm", "cs": return Descriptor(systemName: "c.square", color: Color(hex: 0x6C9EF8))
        case "sh", "bash", "zsh", "fish", "command", "ps1": return Descriptor(systemName: "terminal", color: Color(hex: 0x5FAD65))
        case "sql": return Descriptor(systemName: "cylinder", color: Color(hex: 0x6C9EF8))
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "ico", "heic", "icns": return Descriptor(systemName: "photo", color: Color(hex: 0xC77DBB))
        case "pdf": return Descriptor(systemName: "doc.text.image", color: Color(hex: 0xE55765))
        case "zip", "gz", "tar", "dmg", "jar", "7z", "rar": return Descriptor(systemName: "doc.zipper", color: Color(hex: 0x9DA0A8))
        case "lock": return Descriptor(systemName: "lock.doc", color: Color(hex: 0x9DA0A8))
        case "txt", "log", "text": return Descriptor(systemName: "doc.text", color: Color(hex: 0x9DA0A8))
        case "diff", "patch": return Descriptor(systemName: "plus.forwardslash.minus", color: Color(hex: 0x5FAD65))
        default: break
        }
        if lower.hasPrefix(".git") { return Descriptor(systemName: "arrow.triangle.branch", color: Color(hex: 0xE8A25E)) }
        if lower == "dockerfile" { return Descriptor(systemName: "shippingbox", color: Color(hex: 0x3B8EEA)) }
        if lower == "makefile" || lower == "cmakelists.txt" { return Descriptor(systemName: "hammer", color: Color(hex: 0x9DA0A8)) }
        if lower.hasPrefix("license") { return Descriptor(systemName: "checkmark.seal", color: Color(hex: 0x9DA0A8)) }
        if lower.hasPrefix(".") { return Descriptor(systemName: "gearshape", color: Color(hex: 0x9DA0A8)) }
        return Descriptor(systemName: "doc", color: Color(hex: 0x9DA0A8))
    }
}

public extension View {
    /// 让一个视图整块可点，并且鼠标悬停时显示出底色。
    func hoverHighlight(_ isHovering: Binding<Bool>) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 4).fill(isHovering.wrappedValue ? Theme.hover : .clear))
            .onHover { isHovering.wrappedValue = $0 }
    }
}
