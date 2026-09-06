import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// tooltip 是垫在按钮背景上的一个 NSView，它不能把点击吃掉。
@Test @MainActor func clicksPassThroughTheToolTipLayer() async {
    let clicks = ClickCount()
    let size = CGSize(width: 60, height: 60)
    let hosting = NSHostingView(
        rootView: IconButton("arrow.clockwise", help: "刷新", size: 26) { clicks.value += 1 }
            .frame(width: size.width, height: size.height)
    )
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderBack(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    defer { window.orderOut(nil) }
    await settle(0.3) { false }

    let point = CGPoint(x: size.width / 2, y: size.height / 2)
    // 背景那层的 hitTest 返回 nil，命中的该是上面的 SwiftUI 按钮
    #expect(!(hosting.hitTest(point) is ToolTip.PassThrough))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        window.sendEvent(event)
    }
    await settle(1) { clicks.value > 0 }
    #expect(clicks.value == 1)
}

/// 转一小会儿主 RunLoop 等 SwiftUI 把事件处理完，条件满足就提前收工。
/// 每转 10ms 就 `await` 一次把主线程让出去——测试是并行跑的，死转会把别的 `@MainActor` 测试饿住。
@MainActor private func settle(_ seconds: TimeInterval, until done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !done() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        await Task.yield()
    }
}

@MainActor private final class ClickCount {
    var value = 0
}
