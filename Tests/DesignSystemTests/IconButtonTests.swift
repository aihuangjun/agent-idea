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

/// 主题色是动态色：同一个 `Theme.x` 在浅色 / 深色 appearance 下解析出不同的值，
/// 而且转回 `NSColor`（`FocusedTextField`、`PlainTextEditor`、窗口背景都这么用）之后仍然是动态的。
@Test @MainActor func themeColorsResolvePerAppearance() {
    let light = NSAppearance(named: .aqua)!
    let dark = NSAppearance(named: .darkAqua)!

    func resolve(_ color: Color, in appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    for (color, name) in [(Theme.editorBackground, "editorBackground"), (Theme.panel, "panel"), (Theme.text, "text")] {
        let inLight = resolve(color, in: light)
        let inDark = resolve(color, in: dark)
        #expect(inLight != inDark, "\(name) 在两种外观下应该是不同的颜色")
    }
    // 浅色的编辑器底色是白、文字是深的；深色反过来
    #expect(resolve(Theme.editorBackground, in: light).brightnessComponent > 0.9)
    #expect(resolve(Theme.editorBackground, in: dark).brightnessComponent < 0.2)
    #expect(resolve(Theme.text, in: light).brightnessComponent < 0.3)
    #expect(resolve(Theme.text, in: dark).brightnessComponent > 0.8)
}
