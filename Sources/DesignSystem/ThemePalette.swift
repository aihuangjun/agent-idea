import AppKit
import SwiftUI

/// 一整套配色的原始色值。深色照 IntelliJ 新版 UI 的 Dark，浅色照它的 Light。
///
/// 色值都用 `0xRRGGBB` 存着而不是 `Color`：`web/style.css` 里有同一套变量，
/// `ArchitectureTests` 会把两边的关键色逐个对上（改一边必须改另一边）。
/// 界面上用的是 `Theme` 里的动态颜色，它按窗口当前的 appearance 从这两套里挑。
public struct ThemePalette: Sendable, Equatable {
    // 表面
    public let editorBackground: UInt32
    public let panel: UInt32
    public let border: UInt32
    public let hover: UInt32
    public let selection: UInt32
    public let inactiveSelection: UInt32

    // 文字
    public let text: UInt32
    public let secondaryText: UInt32
    public let mutedText: UInt32

    // 强调
    public let accent: UInt32
    public let danger: UInt32
    public let warning: UInt32
    public let success: UInt32

    // VCS 状态色（IDEA 的 File Status Colors）
    public let vcsModified: UInt32
    public let vcsAdded: UInt32
    public let vcsDeleted: UInt32
    public let vcsConflicted: UInt32
    public let vcsIgnored: UInt32

    // 文件 / 目录图标
    public let folderIcon: UInt32
    public let iconOrange: UInt32
    public let iconAmber: UInt32
    public let iconYellow: UInt32
    public let iconPurple: UInt32
    public let iconBlue: UInt32
    public let iconTeal: UInt32

    // 语法色：Swift 侧只是事实源（正文在 WebView 里，用的是 style.css 顶部同名的 --syn-* 变量），
    // 字段 syntaxFooBar 对应 --syn-foo-bar，ArchitectureTests 逐个核对。前一组 highlight.js / CodeMirror mode 用，
    // 后一组是 tree-sitter 着色（syntax.js）新增的：声明 / 调用、参数、局部、字段、静态 / 全局、类型、类型参数……
    public let syntaxText: UInt32
    public let syntaxComment: UInt32
    public let syntaxDoctag: UInt32
    public let syntaxKeyword: UInt32
    public let syntaxString: UInt32
    public let syntaxNumber: UInt32
    public let syntaxRegexp: UInt32
    public let syntaxFunction: UInt32
    public let syntaxClass: UInt32
    public let syntaxAttr: UInt32
    public let syntaxTag: UInt32
    public let syntaxMeta: UInt32
    public let syntaxCursor: UInt32
    public let syntaxBracketFg: UInt32
    public let syntaxEscape: UInt32
    public let syntaxDocComment: UInt32
    public let syntaxFunctionDecl: UInt32
    public let syntaxFunctionCall: UInt32
    public let syntaxParameter: UInt32
    public let syntaxLocal: UInt32
    public let syntaxField: UInt32
    public let syntaxStatic: UInt32
    public let syntaxType: UInt32
    public let syntaxTypeParam: UInt32
    public let syntaxBuiltin: UInt32
    public let syntaxSelf: UInt32
    public let syntaxOperator: UInt32
    public let syntaxLabel: UInt32

    /// IntelliJ 新版 UI 的 Dark。
    public static let dark = ThemePalette(
        editorBackground: 0x1E1F22,
        panel: 0x2B2D30,
        border: 0x393B40,
        hover: 0x43454A,
        selection: 0x2E436E,
        inactiveSelection: 0x393B40,
        text: 0xDFE1E5,
        secondaryText: 0x9DA0A8,
        mutedText: 0x6F737A,
        accent: 0x3574F0,
        danger: 0xE55765,
        warning: 0xF2C55C,
        success: 0x5FAD65,
        vcsModified: 0x6C9EF8,
        vcsAdded: 0x5FAD65,
        vcsDeleted: 0x868A91,
        vcsConflicted: 0xE55765,
        vcsIgnored: 0x6F737A,
        folderIcon: 0x8C9CB8,
        iconOrange: 0xE8A25E,
        iconAmber: 0xE8C08D,
        iconYellow: 0xD5B778,
        iconPurple: 0xC77DBB,
        iconBlue: 0x56A8F5,
        iconTeal: 0x4DBB94,
        syntaxText: 0xBCBEC4,
        syntaxComment: 0x7A7E85,
        syntaxDoctag: 0x67A37C,
        syntaxKeyword: 0xCF8E6D,
        syntaxString: 0x6AAB73,
        syntaxNumber: 0x2AACB8,
        syntaxRegexp: 0x42C3D1,
        syntaxFunction: 0x56A8F5,
        syntaxClass: 0xBCBEC4,
        syntaxAttr: 0xC77DBB,
        syntaxTag: 0xD5B778,
        syntaxMeta: 0xB3AE60,
        syntaxCursor: 0xDFE1E5,
        syntaxBracketFg: 0xFFEF28,
        syntaxEscape: 0xCF8E6D,
        syntaxDocComment: 0x5F826B,
        syntaxFunctionDecl: 0x56A8F5,
        syntaxFunctionCall: 0x57AAF7,
        syntaxParameter: 0x56C1D6,
        syntaxLocal: 0xBCBEC4,
        syntaxField: 0xC77DBB,
        syntaxStatic: 0xC77DBB,
        syntaxType: 0xB5B6E3,
        syntaxTypeParam: 0x16BAAC,
        syntaxBuiltin: 0x8888C6,
        syntaxSelf: 0x94558D,
        syntaxOperator: 0xBCBEC4,
        syntaxLabel: 0x32B8AF
    )

    /// IntelliJ 新版 UI 的 Light。
    public static let light = ThemePalette(
        editorBackground: 0xFFFFFF,
        panel: 0xF7F8FA,
        border: 0xEBECF0,
        hover: 0xDFE1E5,
        selection: 0xC2D6FC,
        inactiveSelection: 0xE0E2E6,
        text: 0x1E1F22,
        secondaryText: 0x5A5D63,
        mutedText: 0x8A8E96,
        accent: 0x3574F0,
        danger: 0xDB3B4B,
        warning: 0xB8860B,
        success: 0x369650,
        vcsModified: 0x0A62CB,
        vcsAdded: 0x067D17,
        vcsDeleted: 0x6C707E,
        vcsConflicted: 0xC5221F,
        vcsIgnored: 0x8A8E96,
        folderIcon: 0x7F8B99,
        iconOrange: 0xC1691C,
        iconAmber: 0xB07D3B,
        iconYellow: 0x9A7B12,
        iconPurple: 0x9B4F96,
        iconBlue: 0x2E7BC4,
        iconTeal: 0x1F8A76,
        syntaxText: 0x080808,
        syntaxComment: 0x8C8C8C,
        syntaxDoctag: 0x067D17,
        syntaxKeyword: 0x0033B3,
        syntaxString: 0x067D17,
        syntaxNumber: 0x1750EB,
        syntaxRegexp: 0x264EFF,
        syntaxFunction: 0x00627A,
        syntaxClass: 0x000000,
        syntaxAttr: 0x871094,
        syntaxTag: 0x0033B3,
        syntaxMeta: 0x9E880D,
        syntaxCursor: 0x1E1F22,
        syntaxBracketFg: 0xB58900,
        syntaxEscape: 0x0037A6,
        syntaxDocComment: 0x8C8C8C,
        syntaxFunctionDecl: 0x00627A,
        syntaxFunctionCall: 0x36666B,
        syntaxParameter: 0x2A8C7C,
        syntaxLocal: 0x080808,
        syntaxField: 0x871094,
        syntaxStatic: 0x871094,
        syntaxType: 0x336ECC,
        syntaxTypeParam: 0x007E8A,
        syntaxBuiltin: 0x000080,
        syntaxSelf: 0x94558D,
        syntaxOperator: 0x080808,
        syntaxLabel: 0x080808
    )
}

/// 界面外观：跟随系统，或者钉死浅色 / 深色。用户在「视图 → 外观」里选，存 UserDefaults。
public enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 状态栏那个按钮的图标：只按**当前实际**是深色还是浅色来，深色月亮、浅色太阳。
    ///
    /// 以前按档位取图标，跟随系统时是一半一半的圆——可界面那会儿明明就是浅色或深色之一，
    /// 于是同一个主题出现两种图标，看着像三种状态。图标现在只说实际那一档，不说来路。
    public static func symbolName(isDark: Bool) -> String { isDark ? "moon" : "sun.max" }

    /// 状态栏那个按钮点一下换到的档：当前实际是深色就切浅色，反过来也一样。
    /// 跟随系统只从菜单「视图 → 外观」里选，点按钮不会再转回它去。
    public static func toggled(isDark: Bool) -> AppTheme { isDark ? .light : .dark }

    /// 给 `NSApp.appearance` 的值。跟随系统就是 nil（由系统的 appearance 决定）。
    public var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

public extension NSAppearance {
    /// 这份 appearance 算深色吗。`bestMatch` 而不是比名字：vibrant / 高对比度那几种也要归类。
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
