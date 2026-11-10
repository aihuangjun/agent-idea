import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// 等到条件成立，最多 `timeout` 秒。转 10ms 就 yield 一次，别把并行跑的别的 @MainActor 测试饿住（见 AGENTS.md）。
@MainActor private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, !condition() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        await Task.yield()
    }
}

@MainActor private func views(in view: NSView, where match: @MainActor (NSView) -> Bool) -> [NSView] {
    (match(view) ? [view] : []) + view.subviews.flatMap { views(in: $0, where: match) }
}

/// 整个 WorkbenchView 挂进离屏的无边框窗口（带标题栏的窗口里合成的 mouseDown 会被 AppKit 延后重投，见 AGENTS.md）。
@MainActor private func mountWorkbench(_ workbench: WorkbenchModel) -> (NSHostingView<some View>, NSWindow) {
    let size = CGSize(width: 1000, height: 700)
    let view = WorkbenchView()
        .frame(width: size.width, height: size.height)
        .environmentObject(workbench)
        .environmentObject(workbench.preferences)
        .environmentObject(Updater())
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    FirstMouse.enableGlobally()
    window.orderBack(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    return (hosting, window)
}

@MainActor private func click(_ point: CGPoint, in window: NSWindow) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        window.sendEvent(event)
    }
}

/// 每个左侧工具窗口（项目 / 提交 / 提交历史 / 查找）的标题条右侧都有「隐藏（⇧Esc）」按钮，点了就收起
/// （1.7.0 验收：查找窗口展开后找不到地方关）。
@Test @MainActor func everyToolWindowHeaderHasAWorkingHideButton() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "hello".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!,
                                       recentFile: directory.appendingPathComponent("recent.json"))
        let (hosting, window) = mountWorkbench(workbench)
        defer { window.orderOut(nil) }
        workbench.openProject(project)
        hosting.layoutSubtreeIfNeeded()

        @MainActor func hideButton() -> NSView? {
            hosting.layoutSubtreeIfNeeded()
            return views(in: hosting) { $0.toolTip == ToolWindowIcon.hideHelp }.first
        }
        // 从没当过 key 的窗口里第一下点击只用来激活窗口：先在编辑区的空白处暖场点一下
        await waitUntil { hideButton() != nil }
        click(CGPoint(x: 900, y: 300), in: window)

        for toolWindow in [ToolWindow.project, .commit, .history, .find] {
            workbench.toolWindow = toolWindow
            await waitUntil { hideButton() != nil }
            let button = try #require(hideButton(), "\(toolWindow) 的标题条上没有隐藏按钮")
            let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            click(center, in: window)
            await waitUntil { workbench.toolWindow == nil }
            #expect(workbench.toolWindow == nil, "点了 \(toolWindow) 的隐藏按钮没有收起")
        }
        // 收起之后没有标题条，也就没有按钮
        hosting.layoutSubtreeIfNeeded()
        #expect(hideButton() == nil)
    }
}

/// 左侧图标 / ⌘1 再点当前那个就收起；⇧Esc（隐藏工具窗口）收起左边开着的那个，没开时菜单项灰掉。
@Test @MainActor func toolWindowTogglesAndHideOrder() throws {
    try withTemporaryDirectory { directory in
        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!,
                                       recentFile: directory.appendingPathComponent("recent.json"))
        workbench.toolWindow = nil
        #expect(!workbench.canHideToolWindow)

        workbench.toggleToolWindow(.find)
        #expect(workbench.toolWindow == .find)
        workbench.toggleToolWindow(.project)
        #expect(workbench.toolWindow == .project, "点别的是切过去")
        workbench.toggleToolWindow(.project)
        #expect(workbench.toolWindow == nil, "再点当前那个是收起")

        workbench.toolWindow = .find
        #expect(workbench.canHideToolWindow)
        workbench.hideToolWindow()
        #expect(workbench.toolWindow == nil)
        #expect(!workbench.canHideToolWindow)
    }
}

/// Ctrl+F 是「文件内查找」的第二个键位，不再单独占一个菜单项：焦点不在正文里（目录树、窗口本身）时，
/// 窗口的键位分发走遍整个视图层级，由正文 WebView（CursorRestoringWebView.performKeyEquivalent）接下。
@Test @MainActor func controlFOpensFindWithoutItsOwnMenuItem() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!,
                                       recentFile: directory.appendingPathComponent("recent.json"))
        let (hosting, window) = mountWorkbench(workbench)
        defer { window.orderOut(nil) }
        workbench.openProject(file)
        hosting.layoutSubtreeIfNeeded()
        let session = try #require(workbench.active)
        await waitUntil { session.activeTab != nil && workbench.renderer.webView.window === window }
        #expect(!session.isFindShown)

        // 焦点不在 WebView 里
        window.makeFirstResponder(nil)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: "\u{06}", charactersIgnoringModifiers: "f",
                                                  isARepeat: false, keyCode: 3))
        #expect(window.performKeyEquivalent(with: event), "⌃F 没有被窗口里的任何视图接下")
        #expect(session.isFindShown)
    }
}
