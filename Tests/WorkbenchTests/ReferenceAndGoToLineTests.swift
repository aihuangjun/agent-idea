import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor private func cursor(_ renderer: ContentRenderer) async -> String {
    let value = try? await renderer.webView.evaluateJavaScript("(() => { const c = window.ide && window.ide.getState().cursor; return c ? c.line + ':' + c.ch : '' })()")
    return value as? String ?? ""
}

@MainActor private func reference(_ session: ProjectSession, _ tabID: String) async -> String? {
    let result = Locked<String?>(nil)
    session.reference(of: tabID) { result.value = $0 }
    await waitUntil { result.value != nil }
    return result.value
}

/// 查找文件里粘 `路径:行号`：行号拆出来、路径照常搜，打开后跳到那一行（新开的、已经开着的、大文件后台读的都要跳到）；
/// ⌘L 的输入条跳到行；Markdown 预览没有行，跳之前切到分栏；复制引用拼出相对项目根的 `路径:行号`。
@Test @MainActor func pastedReferencesOpenAtTheLineAndGoToLineJumpsWithinTheFile() async throws {
    try await withTemporaryDirectory { directory in
        let sources = directory.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Foo.swift")
        try (1...300).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let readme = directory.appendingPathComponent("README.md")
        try (1...80).map { "paragraph \($0)\n" }.joined(separator: "\n").write(to: readme, atomically: true, encoding: .utf8)
        // 超过同步读的上限：后台读完才画，跳到行要等到那一次渲染
        let big = directory.appendingPathComponent("big.txt")
        try (1...40_000).map { "row \($0) of the big file" }.joined(separator: "\n").write(to: big, atomically: true, encoding: .utf8)

        let suite = "agentidea-reference-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        session.setActive(true)
        defer { session.tearDown() }

        session.search.activate()
        session.search.query = "./Sources/Foo.swift:150:3"
        await waitUntil { session.search.results.first?.entry.path == "Sources/Foo.swift" }
        #expect(session.search.location == SourceLocation(line: 150, column: 3))
        let match = try #require(session.search.selectedResult)
        session.openFile(session.search.url(for: match), pinned: true, at: session.search.location)
        await waitUntil { await cursor(renderer) == "149:2" }
        #expect(await cursor(renderer) == "149:2", "新打开的文件跳到粘进来的行列")

        // 已经是当前标签：不重画，直接跳
        session.openFile(file, pinned: true, at: SourceLocation(line: 10))
        await waitUntil { await cursor(renderer) == "9:0" }
        #expect(await cursor(renderer) == "9:0")

        // ⌘L：格式不对留着输入条提示，对了跳过去并关掉
        session.showGoToLine()
        #expect(session.isGoToLineShown)
        session.setGoToLineText("abc")
        session.submitGoToLine()
        #expect(session.isGoToLineShown && session.goToLineInvalid)
        session.setGoToLineText(" 30:2 ")
        #expect(!session.goToLineInvalid, "改了输入就不再提示错误")
        session.submitGoToLine()
        #expect(!session.isGoToLineShown)
        await waitUntil { await cursor(renderer) == "29:1" }
        #expect(await cursor(renderer) == "29:1")
        let fileTabID = try #require(session.activeTabID)
        #expect(await reference(session, fileTabID) == "Sources/Foo.swift:30")
        #expect(session.referencePath(of: file) == "Sources/Foo.swift", "临时目录的 /var 与 /private/var 也要对上")

        // Markdown 预览没有行：切到分栏再跳
        session.openFile(readme, pinned: true, at: SourceLocation(line: 40))
        await waitUntil { await cursor(renderer) == "39:0" }
        #expect(session.activeTab?.markdownView == .split)
        #expect(await cursor(renderer) == "39:0")
        // 不是当前的标签：用切走时记下的光标
        #expect(await reference(session, fileTabID) == "Sources/Foo.swift:30")

        // 大文件后台读：挂起来，读完画出来的那一次带着跳
        session.openFile(big, pinned: true, at: SourceLocation(line: 30_000))
        #expect(session.activeContent == .loading)
        await waitUntil(20) { await cursor(renderer) == "29999:0" }
        #expect(await cursor(renderer) == "29999:0")
        #expect(session.canGoToLine)
    }
}

/// 对已经是当前标签的文件 `openFile(at:)`：页面直接跳，挂着的行要清掉——否则之后任意一次重画（切主题、换行、切回来）
/// 会再跳一次，还会压掉 diff 的 revealChange 与阅读现场恢复。
@Test @MainActor func directJumpOnTheActiveTabDoesNotLeaveAPendingReveal() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt")
        try (1...200).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let suite = "agentidea-reference-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        session.setActive(true)
        defer { session.tearDown() }

        session.openFile(file, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }
        session.openFile(file, pinned: true, at: SourceLocation(line: 120))
        await waitUntil { await cursor(renderer) == "119:0" }
        #expect(await cursor(renderer) == "119:0")
        #expect(renderer.lastPayload?.revealLine == nil, "直接跳不经过 payload")

        // 用户挪了光标再重画：不该被拉回第 120 行
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setCursor({line: 4, ch: 1}); true")
        session.rerenderActiveTab()
        await waitUntil { renderer.lastPayload?.content.kindName == "code" && renderer.lastPayload?.scrollTop != nil && session.activeTab?.cursor == EditorCursor(line: 4, ch: 1) }
        await waitUntil { await cursor(renderer) == "4:1" }
        #expect(renderer.lastPayload?.revealLine == nil, "重画的 payload 不再带 revealLine")
        #expect(await cursor(renderer) == "4:1")
    }
}

/// 折叠现场随标签走：切到别的文件再切回来（编辑器重建）折叠还在；重画当前标签也在。
@Test @MainActor func foldsFollowTheTabAcrossSwitches() async throws {
    try await withTemporaryDirectory { directory in
        let swift = directory.appendingPathComponent("a.swift")
        try "struct A {\n    func run() {\n        print(1)\n    }\n}\n".write(to: swift, atomically: true, encoding: .utf8)
        let other = directory.appendingPathComponent("b.txt")
        try "other\n".write(to: other, atomically: true, encoding: .utf8)
        let suite = "agentidea-folds-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        session.setActive(true)
        defer { session.tearDown() }
        let folds = "(() => { const node = document.querySelector('.CodeMirror'); return node ? node.CodeMirror.getAllMarks().filter(m => m.__isFold && m.find()).map(m => m.find().from.line).join(',') : 'no editor' })()"
        func current() async -> String { (try? await renderer.webView.evaluateJavaScript(folds)) as? String ?? "" }

        session.openFile(swift, pinned: true)
        await waitUntil { await cursor(renderer) == "0:0" }
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.foldCode({line: 1, ch: 0}, null, 'fold'); true")
        #expect(await current() == "1")

        session.openFile(other, pinned: true)
        await waitUntil { renderer.lastPayload.map { if case .code(let path, _, _, _, _, _, _) = $0.content { return path == other.path } else { return false } } ?? false }
        let swiftTab = EditorTab.id(forFile: swift)
        // 切走时向页面要状态是异步的：等它回来
        await waitUntil { session.tabs.first { $0.id == swiftTab }?.foldState != nil }
        #expect(session.tabs.first { $0.id == swiftTab }?.foldState != nil)
        session.activate(swiftTab)
        await waitUntil { await current() == "1" }
        #expect(await current() == "1", "切回来折叠还在")

        session.rerenderActiveTab()
        await waitUntil { renderer.lastPayload?.foldState != nil }
        await waitUntil { await current() == "1" }
        #expect(await current() == "1")
    }
}
