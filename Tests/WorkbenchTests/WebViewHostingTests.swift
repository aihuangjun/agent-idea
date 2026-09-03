import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// 共用的 WKWebView 在切项目时不能被弄丢：`ProjectContent` 按项目换身份，新旧 `ContentWebView` 会先后搬同一个 WebView，
/// 旧的拆卸时曾把它从新父视图里摘掉，正文一片空白（0.3.0 开发中真出过）。把整个 WorkbenchView 放进离屏窗口走一遍这个流程。
@Test @MainActor func webViewStaysMountedAcrossProjectSwitches() async throws {
    try await withTemporaryDirectory { directory in
        let first = directory.appendingPathComponent("first"), second = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let file = second.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!, recentFile: directory.appendingPathComponent("recent.json"))
        let view = WorkbenchView()
            .frame(width: 1000, height: 700)
            .environmentObject(workbench)
            .environmentObject(workbench.preferences)
            .environmentObject(Updater())
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 700), styleMode: [.titled])
        window.contentView = hosting
        window.orderBack(nil)

        // 像启动时那样：先恢复一个项目，再用文件打开第二个项目（它成为当前项目）
        workbench.openProject(first)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        workbench.openProject(file)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        let webView = workbench.renderer.webView
        #expect(webView.window === window, "WebView 不在窗口里了")
        #expect(webView.frame.width > 100 && webView.frame.height > 100, "WebView 没有尺寸：\(webView.frame)")
        #expect(workbench.active?.activeTab?.title == "a.txt")

        // 再切回第一个项目、再切回来，还得在
        workbench.activate(workbench.sessions[0].id)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        workbench.activate(workbench.sessions[1].id)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(webView.window === window && webView.frame.height > 100)
        window.orderOut(nil)
    }
}

private extension NSWindow {
    convenience init(contentRect: CGRect, styleMode: NSWindow.StyleMask) {
        self.init(contentRect: contentRect, styleMask: styleMode, backing: .buffered, defer: false)
    }
}
