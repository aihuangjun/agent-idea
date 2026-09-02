import AppKit
import DesignSystem
import ObjectiveC
import SwiftUI

/// 拿到承载 SwiftUI 内容的 NSWindow，把标题栏调成与内容无缝：
/// 标题栏透明、去掉它自带的底部分隔线、窗口底色用面板色。红黄绿按钮和标题文字都还在。
///
/// SwiftUI 的 `Window` 场景没有直接改 NSWindow 的入口，只能挂一个空 NSView 进去，等它被放进窗口时动手。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(Theme.panel)
            window.isMovableByWindowBackground = false
            if let contentView = window.contentView {
                FirstMouse.enable(on: type(of: contentView))
            }
        }
    }
}

/// 让窗口不是当前窗口时的第一下点击也算数。
///
/// AppKit 的规矩：点一个非活动窗口，第一下只负责把窗口激活，除非被点的视图对
/// `acceptsFirstMouse(for:)` 回答 true。SwiftUI 生成的视图（宿主视图、滚动视图里的文档视图……）
/// 都沿用 NSView 的默认答案 false，于是从别的窗口移过来点标签要点两下。
///
/// 这些类由 SwiftUI 在运行时生成、拿不到源码，而被点到的也不止一个类（滚动区里的行、标签栏、
/// 工具条各不相同），所以直接把 **NSView 基类** 的默认答案改成 true。
/// 自己重写过这个方法的子类（NSButton、WKWebView 的内部视图等）走自己的实现，不受影响。
enum FirstMouse {
    private static var patched = false

    static func enable(on hostingClass: AnyClass) {
        guard !patched else { return }
        patched = true
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
