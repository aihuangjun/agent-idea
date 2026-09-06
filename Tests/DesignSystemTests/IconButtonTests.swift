import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor private func toolTips(in view: NSView) -> [String] {
    (view.toolTip.map { [$0] } ?? []) + view.subviews.flatMap(toolTips(in:))
}

/// 挂到离屏窗口上，等布局稳定。
@MainActor private func mount<V: View>(_ view: V, size: CGSize = CGSize(width: 120, height: 60)) -> (NSHostingView<V>, NSWindow) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderBack(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    return (hosting, window)
}

/// 工具条上的图标按钮必须真的挂着 tooltip：光看图标猜不出「定位当前文件」是干嘛的。
/// SwiftUI 的 `.help()` 在这套自定义 label + plain 按钮上不落地（NSView 层级里查不到 toolTip），
/// 所以 `IconButton` 走自己的 `ToolTip`。这条测试守着「换回 .help 就会没提示」。
@Test @MainActor func iconButtonCarriesToolTip() {
    let (hosting, window) = mount(IconButton("magnifyingglass", help: "查找文件（⌘F）") {})
    defer { window.orderOut(nil) }
    #expect(toolTips(in: hosting).contains("查找文件（⌘F）"))

    // SwiftUI 自带的 .help 挂不上任何 toolTip——这就是当初提示不出来的原因
    let (plain, plainWindow) = mount(Image(systemName: "magnifyingglass").help("查找文件（⌘F）"))
    defer { plainWindow.orderOut(nil) }
    #expect(toolTips(in: plain).isEmpty)
}
