import AppKit
import Core

/// 正文（WebView）右键菜单的白名单：WebKit 给可编辑文字区域的那一套（拼写和语法、替换、变换、字体、语音、
/// 段落方向 / 选择方向、自动填充、服务、共享、查询……）在代码编辑器里一样都用不上，替换（智能引号）还会改坏代码，
/// IDEA 的编辑器右键里也没有这些。只留：剪切 / 拷贝 / 粘贴 / 全选、翻译，以及我们自己补进去的项。
/// 「用 xx 搜索」（跟着 Safari 的默认搜索引擎，可能是百度）用户明确不要。
///
/// 用白名单而不是黑名单：系统以后再往菜单里加东西也不会冒出来。按 `identifier` / `action` 认，不按标题——
/// 标题随系统语言变（应用包声明了 zh-Hans，中文系统上是中文，别的机器上可能不是）。
enum ContextMenuPruning {
    /// WebKit 的 `WKMenuItemIdentifier*`（常量的值就是名字本身）。2026-11 在 macOS 27 上实测右键可编辑区域的原样
    /// （`describe` 的日志）：拷贝 / 粘贴 / 翻译有 identifier；翻译叫 `…Translate`（不是 `…TranslateMenu`）。
    static let keptIdentifiers: Set<String> = [
        "WKMenuItemIdentifierCopy",
        "WKMenuItemIdentifierPaste",
        "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierTranslateMenu",
    ]

    /// 「剪切」WebKit 不给 identifier（实测 identifier 是 `forwardContextMenuAction:`），只能认 WebCore 的
    /// `ContextMenuItemTagCut`（13），且只认 WebKit 自己转发动作的项，免得误留别人 tag 恰好是 13 的项。
    static let webKitCutTag = 13
    static let webKitForwardAction = "forwardContextMenuAction:"

    /// AppKit 文本控件那套标准编辑项按 action 认（WebView 之外的菜单、或 WebKit 将来改成标准 action 时）。
    static let keptActions: Set<String> = ["cut:", "copy:", "paste:", "selectAll:", "pasteAsPlainText:"]

    static func keeps(_ item: NSMenuItem) -> Bool {
        if item.isSeparatorItem { return true }
        if let identifier = item.identifier?.rawValue, keptIdentifiers.contains(identifier) { return true }
        guard let action = item.action.map(NSStringFromSelector) else { return false }
        if keptActions.contains(action) { return true }
        return action == webKitForwardAction && item.tag == webKitCutTag && !item.hasSubmenu
    }

    /// 就地删掉白名单以外的项，再把分隔线收拾干净（不留在开头、结尾，不连着两条）。
    static func prune(_ menu: NSMenu) {
        for item in menu.items where !keeps(item) {
            menu.removeItem(item)
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator {
                menu.removeItem(item)
            } else {
                previousWasSeparator = item.isSeparatorItem
            }
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }

    /// 排查用：菜单里每一项的 identifier / action / 标题，一行一项。只在每个进程第一次打开右键菜单时记一次日志，
    /// 系统换了 identifier 导致该留的被删时，从日志里一眼看得出来。
    static func describe(_ menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            let identifier = item.identifier?.rawValue ?? "-"
            let action = item.action.map(NSStringFromSelector) ?? "-"
            return "\(item.title) [\(identifier) \(action) tag=\(item.tag)\(item.hasSubmenu ? " ▸" : "")]"
        }.joined(separator: "; ")
    }
}
