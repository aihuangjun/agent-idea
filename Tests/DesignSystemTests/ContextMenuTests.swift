import AppKit
import Testing
@testable import DesignSystem

@Test @MainActor func webContextMenuKeepsStandardItemsAndRunsTheCapturedAction() throws {
    let renderer = ContentRenderer()
    let webView = try #require(renderer.webView as? CursorRestoringWebView)
    var performed = 0
    renderer.contextActions = { [.init(title: "回滚") { performed += 1 }] }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
    webView.willOpenMenu(menu, with: event)
    #expect(menu.items.map(\.title) == ["回滚", "", "Copy"])
    let item = try #require(menu.items.first)
    renderer.contextActions = { [] }
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(performed == 1)

    let plain = NSMenu()
    plain.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
    webView.willOpenMenu(plain, with: event)
    #expect(plain.items.map(\.title) == ["Copy"])
}

/// WebKit 给可编辑文字的那一套（拼写、替换、字体、语音、段落方向、自动填充、服务……）在代码编辑器里没用：
/// 只留剪切 / 拷贝 / 粘贴 / 全选、翻译（「用 xx 搜索」也不要），按 identifier / action 认、不看标题；分隔线不留在头尾、不连着。
@Test @MainActor func webContextMenuDropsWritingToolsAndKeepsEditingItems() throws {
    // 照 macOS 27 上 WebKit 实际给出的样子（ContextMenuPruning.describe 的日志）
    let forward = NSSelectorFromString("forwardContextMenuAction:")
    func item(_ title: String, identifier: String? = nil, action: Selector? = nil, tag: Int = 0, submenu: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier) }
        item.tag = tag
        if submenu { item.submenu = NSMenu(title: title) }
        return item
    }
    let menu = NSMenu()
    menu.addItem(item("查询", identifier: "WKMenuItemIdentifierLookUp", action: forward, tag: 22))
    menu.addItem(item("翻译", identifier: "WKMenuItemIdentifierTranslate", action: forward, tag: 95))
    menu.addItem(.separator())
    menu.addItem(item("搜索", identifier: "WKMenuItemIdentifierSearchWeb", action: forward, tag: 21))
    menu.addItem(.separator())
    menu.addItem(item("剪切", identifier: "forwardContextMenuAction:", action: forward, tag: 13))
    menu.addItem(item("拷贝", identifier: "WKMenuItemIdentifierCopy", action: forward, tag: 8))
    menu.addItem(item("粘贴", identifier: "WKMenuItemIdentifierPaste", action: forward, tag: 14))
    menu.addItem(.separator())
    menu.addItem(.separator())
    menu.addItem(item("自动填充", identifier: "_NSMenuItemAutoFillIdentifier", submenu: true))
    menu.addItem(item("拼写和语法", identifier: "WKMenuItemIdentifierSpellingMenu", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(item("替换", identifier: "WKMenuItemIdentifierSubstitutionsMenu", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(item("转换", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(item("字体", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(item("语音", identifier: "WKMenuItemIdentifierSpeechMenu", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(item("段落方向", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(item("选择方向", action: NSSelectorFromString("submenuAction:"), submenu: true))
    menu.addItem(.separator())
    menu.addItem(item("共享…", identifier: "WKMenuItemIdentifierShareMenu", action: NSSelectorFromString("performShare:")))
    // 别的项 tag 恰好是 13 但不是 WebKit 转发的动作：不能当成剪切留下
    menu.addItem(item("冒充", action: NSSelectorFromString("other:"), tag: 13))

    ContextMenuPruning.prune(menu)
    #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["翻译", "—", "剪切", "拷贝", "粘贴"])
}
