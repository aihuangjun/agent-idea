import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// 同步地转一小会儿主 RunLoop。
@MainActor private func spinRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
    }
}

/// 项目标签的顺序能改，而且要留住：下次启动是照 `openProjects` 的顺序开回来的。
@Test @MainActor func projectTabsReorderAndTheOrderIsRemembered() async throws {
    try await withTemporaryDirectory { directory in
        let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
        for name in ["a", "b", "c"] {
            let root = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            workbench.openProject(root)
        }
        #expect(workbench.sessions.map(\.project.name) == ["a", "b", "c"])

        workbench.moveProject(from: 0, to: 2)
        #expect(workbench.sessions.map(\.project.name) == ["b", "c", "a"])
        #expect(workbench.active?.project.name == "c", "换顺序不换当前项目")
        workbench.moveProject(from: 2, to: 0)
        #expect(workbench.sessions.map(\.project.name) == ["a", "b", "c"])
        workbench.moveProject(from: 1, to: 1)
        workbench.moveProject(from: 9, to: 0)
        workbench.moveProject(from: 0, to: -1)
        #expect(workbench.sessions.map(\.project.name) == ["a", "b", "c"], "原地不动与越界都不该动")

        workbench.moveProject(from: 2, to: 0)
        let restored = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
        restored.restoreOpenProjects()
        #expect(restored.sessions.map(\.project.name) == ["c", "a", "b"], "重开还是拖过之后的顺序")
    }
}

/// 把项目标签行挂进离屏窗口合成鼠标事件：空白处双击 = 打开项目；标签往右拖过头就排到最后。
@Test @MainActor func headerBarDragsTabsAndOpensProjectOnBlankDoubleClick() async throws {
    try await withTemporaryDirectory { directory in
        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!,
                                       recentFile: directory.appendingPathComponent("recent.json"))
        for name in ["alpha", "bravo", "charlie"] {
            let root = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            workbench.openProject(root)
        }

        let opens = Locked(0)
        let size = CGSize(width: 900, height: 28)
        let view = HeaderBar(openProject: { opens.value += 1 })
            .frame(width: size.width, height: size.height)
            .environmentObject(workbench)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        // 不是当前窗口时第一下点击默认只负责激活窗口（应用里由 WindowConfigurator 关掉这条）
        FirstMouse.enableGlobally()
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        defer { window.orderOut(nil) }

        @MainActor func send(_ type: NSEvent.EventType, x: Double, clickCount: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: size.height / 2), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: clickCount, pressure: 0)!
            window.sendEvent(event)
        }
        // 转一小段就 yield 一次：一口气转几秒会把并行跑的别的 @MainActor 测试饿住（见 AGENTS.md）
        @MainActor func settle(_ seconds: TimeInterval = 0.3) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                spinRunLoop(0.01)
                await Task.yield()
            }
            hosting.layoutSubtreeIfNeeded()
        }

        // 三个标签加起来远不到 900：x = 800 一定是空白
        send(.leftMouseDown, x: 800)
        send(.leftMouseUp, x: 800)
        send(.leftMouseDown, x: 800, clickCount: 2)
        send(.leftMouseUp, x: 800, clickCount: 2)
        await settle()
        #expect(opens.value == 1, "空白处双击该去打开项目")
        #expect(workbench.sessions.map(\.project.name) == ["alpha", "bravo", "charlie"], "双击空白不该动顺序")

        // 双击在标签上只是切项目，别把选目录面板也弹出来
        send(.leftMouseDown, x: 20)
        send(.leftMouseUp, x: 20)
        send(.leftMouseDown, x: 20, clickCount: 2)
        send(.leftMouseUp, x: 20, clickCount: 2)
        await settle()
        #expect(opens.value == 1, "双击标签不该当成双击空白")
        #expect(workbench.active?.project.name == "alpha")

        // 第一个标签往右拖过头：排到最后，当前项目跟着切成它
        send(.leftMouseDown, x: 20)
        for x in stride(from: 40.0, through: 700, by: 60) {
            send(.leftMouseDragged, x: x)
            await settle(0.02)
        }
        send(.leftMouseUp, x: 700)
        await settle()
        #expect(workbench.sessions.map(\.project.name) == ["bravo", "charlie", "alpha"])
        #expect(workbench.active?.project.name == "alpha", "拖之前先切过去，跟点一下一样")

        // 往左也能拖。x = 150 落在第二或第三个标签上（标签多宽取决于名字，不猜）：
        // 拖动会先把按住的那个切成当前项目，拖完照它断言——它该排到了最前面，别人相对顺序不变。
        let before = workbench.sessions.map(\.project.name)
        send(.leftMouseDown, x: 150)
        for x in stride(from: 130.0, through: -400, by: -60) {
            send(.leftMouseDragged, x: x)
            await settle(0.02)
        }
        send(.leftMouseUp, x: -400)
        await settle()
        let dragged = try #require(workbench.active?.project.name)
        #expect(dragged != before[0], "x = 150 该落在第一个标签之外")
        #expect(workbench.sessions.map(\.project.name) == [dragged] + before.filter { $0 != dragged })

        // 标签上的关闭按钮不能被拖动手势抢走（它在标签里面，拖动挂在标签上）。
        // 按钮的位置从它自己的提示视图上取——`toolTip` 是铺在按钮背景上的 NSView，frame 就是按钮的。
        @MainActor func closeButtons(in view: NSView) -> [NSView] {
            (view.toolTip == "关闭项目" ? [view] : []) + view.subviews.flatMap { closeButtons(in: $0) }
        }
        let close = try #require(closeButtons(in: hosting).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        let center = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        send(.leftMouseDown, x: center.x)
        send(.leftMouseUp, x: center.x)
        await settle()
        #expect(workbench.sessions.map(\.project.name) == before.filter { $0 != dragged }, "点 ✕ 该关掉第一个标签的项目")
    }
}

/// 慢慢拖（小步长）时顺序只能往一个方向走，不能来回跳：跳一下就是屏幕上高频闪烁。
///
/// 拖动手势的位移一旦按**标签自己的**坐标系算，就会这样：标签让位往右挪了 Δ，光标在它局部坐标里
/// 就往左退了 Δ，位移跟着减 Δ、落点退回原来那一格，下一拍又挪回去——每一帧换一次位。
@Test @MainActor func draggingATabDoesNotOscillate() async throws {
    try await withTemporaryDirectory { directory in
        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!,
                                       recentFile: directory.appendingPathComponent("recent.json"))
        for name in ["alpha", "bravo", "charlie"] {
            let root = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            workbench.openProject(root)
        }

        let size = CGSize(width: 900, height: 28)
        let hosting = NSHostingView(rootView: HeaderBar(openProject: {}).frame(width: size.width, height: size.height).environmentObject(workbench))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        FirstMouse.enableGlobally()
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        defer { window.orderOut(nil) }

        @MainActor func send(_ type: NSEvent.EventType, x: Double) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: size.height / 2), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            window.sendEvent(event)
        }
        @MainActor func settle(_ seconds: TimeInterval) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                spinRunLoop(0.01)
                await Task.yield()
            }
            hosting.layoutSubtreeIfNeeded()
        }

        send(.leftMouseDown, x: 20)
        var indexes: [Int] = []
        // 步子小才看得见来回跳；也别太多步——测试是并行跑的，主线程占太久会把别的用例饿超时
        for x in stride(from: 26.0, through: 320, by: 6) {
            send(.leftMouseDragged, x: x)
            await settle(0.015)
            indexes.append(workbench.sessions.firstIndex { $0.project.name == "alpha" } ?? -1)
        }
        send(.leftMouseUp, x: 320)
        await settle(0.2)

        #expect(indexes.last == 2, "拖到最右该排到最后（实际走位：\(indexes)）")
        #expect(zip(indexes, indexes.dropFirst()).allSatisfy { $0 <= $1 }, "一路往右拖，位置不该往回跳：\(indexes)")
    }
}
