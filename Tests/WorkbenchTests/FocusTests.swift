import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// ⌘F / 点放大镜打开查找文件时，焦点得真的到搜索框里——哪怕之前第一响应者是正文的 WKWebView
/// （SwiftUI 的 FocusState 在这种情况下拿不到焦点，0.5.0 改成 NSTextField 直包）。整个 WorkbenchView 放进离屏窗口走一遍。
@Test @MainActor func fileSearchTakesKeyboardFocusFromWebView() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!, recentFile: directory.appendingPathComponent("recent.json"))
        let view = WorkbenchView()
            .frame(width: 1000, height: 700)
            .environmentObject(workbench)
            .environmentObject(workbench.preferences)
            .environmentObject(Updater())
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        workbench.openProject(file)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        let session = try #require(workbench.active)
        // 用户正在编辑器里：WebView 是第一响应者
        window.makeFirstResponder(workbench.renderer.webView)
        #expect(window.firstResponder === workbench.renderer.webView)

        // ⌘F（菜单项做的就是这两步）
        workbench.toolWindow = .project
        session.search.activate()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(searchFieldIsFirstResponder(in: window), "打开搜索后焦点应在搜索框里，现在是 \(String(describing: window.firstResponder))")

        // 搜索已经开着、焦点又回到编辑器，再按一次 ⌘F 也得把焦点抢回来
        window.makeFirstResponder(workbench.renderer.webView)
        session.search.activate()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(searchFieldIsFirstResponder(in: window), "再次 ⌘F 焦点应回到搜索框，现在是 \(String(describing: window.firstResponder))")
    }
}

/// 重命名对话框一打开焦点就在名字框里，且选中的是扩展名之前那一段（IDEA 一样）。
@Test @MainActor func renameSheetFocusesNameAndSelectsStem() async throws {
    let node = FileNode(url: URL(fileURLWithPath: "/tmp/x/main.swift"), name: "main.swift", isDirectory: false)
    let committed = Locked<String?>(nil)
    let sheet = RenameSheet(node: node) { name in FileRename.validate(name, currentName: node.name) { $0 == "taken.swift" } } commit: { committed.value = $0 }
    let hosting = NSHostingView(rootView: sheet)
    hosting.frame = CGRect(x: 0, y: 0, width: 420, height: 180)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 420, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 300_000_000)

    // AGENTIDEA_SNAPSHOT_DIR 设了就把对话框的样子导出来看
    if let snapshotDirectory = ProcessInfo.processInfo.environment["AGENTIDEA_SNAPSHOT_DIR"],
       let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("rename-sheet.png"))
    }

    let editor = try #require(window.firstResponder as? NSTextView, "焦点应在名字框里，现在是 \(String(describing: window.firstResponder))")
    let field = try #require(editor.delegate as? FocusedTextField.Field)
    #expect(field.stringValue == "main.swift")
    #expect(editor.selectedRange() == NSRange(location: 0, length: 4), "选中扩展名之前的 main")

    // 敲出一个新名字再按回车：交给 commit
    editor.insertText("renamed", replacementRange: editor.selectedRange())
    #expect(field.stringValue == "renamed.swift")
    // 走 doCommand(by:)：按键就是这么进来的；直接调 insertNewline 不会经过 delegate
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(committed.value == "renamed.swift")
}

/// 窗口的第一响应者是不是搜索框（NSTextField 编辑时第一响应者是它的字段编辑器，delegate 指回输入框）。
@MainActor
private func searchFieldIsFirstResponder(in window: NSWindow) -> Bool {
    guard let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? FocusedTextField.Field else { return false }
    return field.placeholderAttributedString?.string == "查找文件名或路径"
}
