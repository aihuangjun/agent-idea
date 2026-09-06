import AppKit
import SwiftUI

/// 应用配色：照 IntelliJ 新版 UI 的深色 / 浅色主题。
///
/// 每个颜色都是**动态色**（`NSColor(name:dynamicProvider:)`）：窗口的 appearance 一变，
/// AppKit 自己按 `ThemePalette.dark` / `.light` 重新解析，界面代码一行都不用改。
/// 外观由「视图 → 外观」写进 `NSApp.appearance`（见 `AppTheme`）。
///
/// 色值的事实源是 `ThemePalette`；`Resources/web/style.css` 顶部有同一套 CSS 变量
/// （正文渲染在 WebView 里、外壳在 SwiftUI 里），架构测试核对两边对得上。
public enum Theme {
    /// 按当前 appearance 取色的动态颜色。
    private static func dynamic(_ key: KeyPath<ThemePalette, UInt32>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: (appearance.isDark ? ThemePalette.dark : ThemePalette.light)[keyPath: key])
        })
    }

    // MARK: - 表面

    /// 编辑器底色。
    public static let editorBackground = dynamic(\.editorBackground)
    /// 面板（工具窗口、标签栏、状态栏）。
    public static let panel = dynamic(\.panel)
    /// 分隔线与描边。
    public static let border = dynamic(\.border)
    /// 悬停底色。
    public static let hover = dynamic(\.hover)
    /// 选中行（有焦点）。
    public static let selection = dynamic(\.selection)
    /// 选中行（无焦点）。
    public static let inactiveSelection = dynamic(\.inactiveSelection)

    // MARK: - 文字

    /// 主文字。
    public static let text = dynamic(\.text)
    /// 次要文字。
    public static let secondaryText = dynamic(\.secondaryText)
    /// 更弱的文字（行号、占位）。
    public static let mutedText = dynamic(\.mutedText)

    // MARK: - 强调

    /// IntelliJ 蓝：强调色、当前标签下划线。
    public static let accent = dynamic(\.accent)
    /// 错误。
    public static let danger = dynamic(\.danger)
    /// 警告。
    public static let warning = dynamic(\.warning)
    /// 成功。
    public static let success = dynamic(\.success)

    // MARK: - VCS 状态色（IDEA 的 File Status Colors）

    /// 修改：蓝
    public static let vcsModified = dynamic(\.vcsModified)
    /// 新增（已加入 git）：绿
    public static let vcsAdded = dynamic(\.vcsAdded)
    /// 未跟踪：也用绿——用户眼里它就是「新文件」；列表上另有「未跟踪」标签区分。
    public static let vcsUntracked = dynamic(\.vcsAdded)
    /// 删除：灰，配删除线
    public static let vcsDeleted = dynamic(\.vcsDeleted)
    /// 重命名 / 移动：IDEA 没有单独的颜色，按「修改」显示成蓝（0.6.0 前是青绿，与新增的绿放一起像两种绿）。
    public static let vcsRenamed = dynamic(\.vcsModified)
    /// 冲突：红
    public static let vcsConflicted = dynamic(\.vcsConflicted)
    /// 忽略：灰（比删除更暗一点，且不带删除线）
    public static let vcsIgnored = dynamic(\.vcsIgnored)

    // MARK: - 图标色（只给文件/目录图标用）

    /// 目录图标的灰蓝。
    public static let folderIcon = dynamic(\.folderIcon)
    public static let iconOrange = dynamic(\.iconOrange)
    public static let iconAmber = dynamic(\.iconAmber)
    public static let iconYellow = dynamic(\.iconYellow)
    public static let iconPurple = dynamic(\.iconPurple)
    public static let iconBlue = dynamic(\.iconBlue)
    public static let iconTeal = dynamic(\.iconTeal)

    // MARK: - 字体

    public static let uiFont = Font.system(size: 13)
    public static let smallFont = Font.system(size: 11)

    // MARK: - 尺寸

    public static let treeRowHeight: CGFloat = 22
    public static let toolStripWidth: CGFloat = 40
    public static let tabHeight: CGFloat = 34
    public static let statusBarHeight: CGFloat = 24
}

public extension Color {
    /// `Color(hex: 0x1E1F22)`。sRGB。
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

public extension NSColor {
    /// `NSColor(hex: 0x1E1F22)`。sRGB。
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
