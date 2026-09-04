import SwiftUI

/// 应用配色：照 IntelliJ 新版 UI 的深色主题（Dark）。
///
/// 与 `Resources/web/style.css` 顶部的 CSS 变量是同一套色值——正文渲染在 WebView 里、
/// 外壳在 SwiftUI 里，两边必须对齐，改一处记得改另一处。
public enum Theme {
    // MARK: - 表面

    /// #1E1F22 编辑器底色。
    public static let editorBackground = Color(hex: 0x1E1F22)
    /// #2B2D30 面板（工具窗口、标签栏、状态栏）。
    public static let panel = Color(hex: 0x2B2D30)
    /// #393B40 分隔线与描边。
    public static let border = Color(hex: 0x393B40)
    /// #43454A 悬停底色。
    public static let hover = Color(hex: 0x43454A)
    /// #2E436E 选中行（有焦点）。
    public static let selection = Color(hex: 0x2E436E)
    /// #393B40 选中行（无焦点）。
    public static let inactiveSelection = Color(hex: 0x393B40)

    // MARK: - 文字

    /// #DFE1E5 主文字。
    public static let text = Color(hex: 0xDFE1E5)
    /// #9DA0A8 次要文字。
    public static let secondaryText = Color(hex: 0x9DA0A8)
    /// #6F737A 更弱的文字（行号、占位）。
    public static let mutedText = Color(hex: 0x6F737A)

    // MARK: - 强调

    /// #3574F0 IntelliJ 蓝：强调色、当前标签下划线。
    public static let accent = Color(hex: 0x3574F0)
    /// #E55765 错误。
    public static let danger = Color(hex: 0xE55765)
    /// #F2C55C 警告。
    public static let warning = Color(hex: 0xF2C55C)
    /// #5FAD65 成功。
    public static let success = Color(hex: 0x5FAD65)

    // MARK: - VCS 状态色（IDEA 的 File Status Colors，深色主题）

    /// 修改：蓝 #6C9EF8
    public static let vcsModified = Color(hex: 0x6C9EF8)
    /// 新增（已加入 git）：绿 #5FAD65
    public static let vcsAdded = Color(hex: 0x5FAD65)
    /// 未跟踪：也用绿——用户眼里它就是「新文件」；列表上另有「未跟踪」标签区分。
    public static let vcsUntracked = Color(hex: 0x5FAD65)
    /// 删除：灰 #868A91，配删除线
    public static let vcsDeleted = Color(hex: 0x868A91)
    /// 重命名 / 移动：IDEA 没有单独的颜色，按「修改」显示成蓝（0.6.0 前是青绿 #4DBB94，与新增的绿放一起像两种绿）。
    public static let vcsRenamed = vcsModified
    /// 冲突：红 #E55765
    public static let vcsConflicted = Color(hex: 0xE55765)
    /// 忽略：灰 #6F737A（比删除更暗一点，且不带删除线）
    public static let vcsIgnored = Color(hex: 0x6F737A)

    // MARK: - 图标色（只给文件/目录图标用）

    /// #8C9CB8 目录图标的灰蓝。
    public static let folderIcon = Color(hex: 0x8C9CB8)
    public static let iconOrange = Color(hex: 0xE8A25E)
    public static let iconAmber = Color(hex: 0xE8C08D)
    public static let iconYellow = Color(hex: 0xD5B778)
    public static let iconPurple = Color(hex: 0xC77DBB)
    public static let iconBlue = Color(hex: 0x56A8F5)
    public static let iconTeal = Color(hex: 0x4DBB94)

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
