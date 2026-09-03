import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// 同步地转一小会儿主 RunLoop（`RunLoop.run(until:)` 不让在 async 上下文里直接调）。
@MainActor private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 变更列表的高亮只跟着当前标签走：点了第二个文件，第一个的高亮必须消失。
/// 0.3.0 里行视图自己去读 `session.activeTab`，SwiftUI 看不出行有变化就不重画，点过的行全亮着。
/// 把 ChangesView 放进离屏窗口，合成点击两行，再把视图画成位图看两行的底色。
@Test @MainActor func clickingAnotherChangeMovesTheHighlight() async throws {
    try await withTemporaryDirectory { directory in
        try "v2\n".write(to: directory.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: directory.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path + "\n")
            case "rev-parse": return shellOutput("abc")
            case "status": return shellOutput("# branch.oid abc\u{0}# branch.head main\u{0}1 .M N... 100644 100644 100644 a b m.txt\u{0}1 .D N... 100644 100644 000000 a a gone.txt\u{0}? n.txt\u{0}")
            case "show" where arguments.last == "HEAD:m.txt": return shellOutput("v1\n")
            case "show": return ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: not in HEAD")
            case "diff": return shellOutput("diff --git a/gone.txt b/gone.txt\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n")
            default: return shellOutput("")
            }
        }
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        session.setActive(true)
        let deadline = Date().addingTimeInterval(3)
        while session.changeGroups.total != 3, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let tracked = session.changeGroups.tracked
        #expect(tracked.count == 2)

        let size = CGSize(width: 320, height: 400)
        let hosting = NSHostingView(rootView: ChangesView(session: session).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        // 屏幕外的窗口：合成事件要窗口真的存在于窗口服务器里才会被派发，但不能让用户看见、也不抢焦点
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        // 不是当前窗口时第一下点击默认只负责激活窗口；应用启动时也是这么打开的（WindowConfigurator）
        FirstMouse.enableGlobally()
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)

        // 行的位置：标题条 32 + 上边距 4 + 分组标题 22，然后每行 22
        func rowCenter(_ index: Int) -> CGPoint {
            let top = 32.0 + 4 + 22 + Double(index) * 22 + 11
            return CGPoint(x: 8, y: size.height - top)
        }
        @MainActor func click(_ point: CGPoint) async throws {
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                window.sendEvent(event)
            }
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                spin(0.01)
                await Task.yield()
            }
            hosting.layoutSubtreeIfNeeded()
        }
        @MainActor func rowColor(_ index: Int) throws -> (Int, Int, Int) {
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / size.width
            let point = rowCenter(index)
            // 位图原点在左上角
            let color = try #require(rep.colorAt(x: Int(point.x * scale), y: Int((size.height - point.y) * scale))?.usingColorSpace(.sRGB))
            return (Int(color.redComponent * 255 + 0.5), Int(color.greenComponent * 255 + 0.5), Int(color.blueComponent * 255 + 0.5))
        }
        func isSelection(_ rgb: (Int, Int, Int)) -> Bool {
            // Theme.selection = 0x2E436E 是明显偏蓝的；面板底色 0x2B2D30 与悬停色 0x43454A 都是灰的。
            // 位图经过色彩空间转换后数值会整体偏移（实测选中色采成 (65, 85, 126)），所以只看蓝与红的差。
            rgb.2 - rgb.0 > 40 && rgb.2 > 90
        }

        try await click(rowCenter(0))
        #expect(session.activeTab?.change?.path == tracked[0].path)
        let afterFirst = (try rowColor(0), try rowColor(1))
        #expect(isSelection(afterFirst.0) && !isSelection(afterFirst.1), "点第一行后：\(afterFirst)")

        try await click(rowCenter(1))
        #expect(session.activeTab?.change?.path == tracked[1].path)
        let afterSecond = (try rowColor(0), try rowColor(1))
        #expect(!isSelection(afterSecond.0) && isSelection(afterSecond.1), "点第二行后第一行的高亮没消失：\(afterSecond)")
        window.orderOut(nil)
    }
}
