import AppKit
import Testing
@testable import DesignSystem

@Test @MainActor func webContextMenuKeepsStandardItemsAndRunsTheCapturedAction() throws {
    let renderer = ContentRenderer()
    let webView = try #require(renderer.webView as? CursorRestoringWebView)
    var performed = 0
    renderer.contextActions = { [.init(title: "回滚（Revert）") { performed += 1 }] }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
    webView.willOpenMenu(menu, with: event)
    #expect(menu.items.map(\.title) == ["回滚（Revert）", "", "Copy"])
    let item = try #require(menu.items.first)
    renderer.contextActions = { [] }
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(performed == 1)

    let plain = NSMenu()
    plain.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
    webView.willOpenMenu(plain, with: event)
    #expect(plain.items.map(\.title) == ["Copy"])
}
