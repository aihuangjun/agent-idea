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

@MainActor private func editorText(_ renderer: ContentRenderer) async -> String? {
    try? await renderer.webView.evaluateJavaScript("(() => { const s = window.ide && window.ide.getState(); return s ? s.text : null })()") as? String
}

@MainActor private func undoInEditor(_ renderer: ContentRenderer) async -> Bool {
    await withCheckedContinuation { continuation in renderer.undo { continuation.resume(returning: $0) } }
}

/// 一个项目目录 + 一个与之分开的存档目录，挂在真 WebView 上的 workbench（edited 消息、onEditorHistory 都按应用里的接法走）。
@MainActor private func makeWorkbench(project: URL, store: EditorHistoryStore, directory: URL) -> (WorkbenchModel, NSWindow) {
    let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!,
                                   recentFile: directory.appendingPathComponent("recent.json"), editorHistories: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = workbench.renderer.webView
    workbench.openProject(project)
    return (workbench, window)
}

/// 编辑 → 退出那一段同步保存就把历史存了（与刚写盘的文字对得上，CRLF 文件也一样）→ 关标签 → 重命名 → 在新路径重开 → ⌘Z 撤回关之前的那一步。
@Test @MainActor func editorUndoHistorySurvivesClosingTheTabAndRenaming() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.txt")
        try "one\r\ntwo\r\n".write(to: file, atomically: true, encoding: .utf8)
        let undoDirectory = directory.appendingPathComponent("undo")
        let store = EditorHistoryStore(directory: undoDirectory)
        let (workbench, window) = makeWorkbench(project: project, store: store, directory: directory)
        defer { workbench.closeProject(); window.contentView = nil }
        let session = try #require(workbench.active)
        let renderer = workbench.renderer

        session.openFile(file, pinned: true)
        await waitUntil { await editorText(renderer) == "one\ntwo\n" }
        let tab = try #require(session.activeTab)
        let path = try #require(session.documentURL(for: tab)).path
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.replaceRange('X', {line: 0, ch: 0}); true")
        // edited 消息停手 300ms 才发，带着文字与历史
        await waitUntil { session.isModified(tab) && session.tabs.first?.history?.textHash == EditorHistory.hash("Xone\ntwo\n") }

        // 退出：willTerminate 里只有 saveAll 的同步段来得及——它一返回，草稿与对应的历史就都在盘上了
        workbench.saveAll()
        #expect(try String(contentsOf: file, encoding: .utf8) == "Xone\r\ntwo\r\n", "按原来的 CRLF 写回")
        let restarted = EditorHistoryStore(directory: undoDirectory)
        let stored = try #require(restarted.entries[path], "新实例（重启后）读得到")
        #expect(stored.textHash == TextFingerprint.of("Xone\r\ntwo\r\n"), "指纹按行尾归一后的文本算，与磁盘上的 CRLF 对得上")

        session.closeTab(tab.id)
        await waitUntil { session.tabs.isEmpty }

        // 关着的文件改名：存档跟着换路径
        session.rename(FileNode(url: file, name: "a.txt", isDirectory: false), to: "b.txt")
        let renamed = project.appendingPathComponent("b.txt")
        let renamedPath = ProjectSession.historyKey(renamed)
        await waitUntil { store.entries[renamedPath] != nil }
        #expect(store.entries[path] == nil && store.entries[renamedPath] != nil)

        session.openFile(renamed, pinned: true)
        await waitUntil { await editorText(renderer) == "Xone\ntwo\n" }
        #expect(session.activeTab?.history != nil, "从存档装回来")
        #expect(await undoInEditor(renderer))
        #expect(await editorText(renderer) == "one\ntwo\n", "⌘Z 撤回关标签之前的那一笔")
    }
}

/// 关着的时候文件被别人（Agent）改了：重开时指纹对不上，不装回、存档删掉，⌘Z 不会撕坏正文。
@Test @MainActor func storedUndoHistoryIsDiscardedWhenTheFileChangedOnDisk() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.txt")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        let store = EditorHistoryStore(directory: directory.appendingPathComponent("undo"))
        let (workbench, window) = makeWorkbench(project: project, store: store, directory: directory)
        defer { workbench.closeProject(); window.contentView = nil }
        let session = try #require(workbench.active)
        let renderer = workbench.renderer

        session.openFile(file, pinned: true)
        await waitUntil { await editorText(renderer) == "one\ntwo\n" }
        let tab = try #require(session.activeTab)
        let path = try #require(session.documentURL(for: tab)).path
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.replaceRange('X', {line: 1, ch: 3}); true")
        // 关当前标签会先问一次编辑器（不等 edited）：文字与历史都是此刻的
        session.closeTab(tab.id)
        await waitUntil { session.tabs.isEmpty }
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwoX\n")
        #expect(store.entries[path] != nil)

        try "changed by agent\n".write(to: file, atomically: true, encoding: .utf8)
        session.openFile(file, pinned: true)
        await waitUntil { await editorText(renderer) == "changed by agent\n" }
        #expect(session.activeTab?.history == nil)
        #expect(store.entries[path] == nil, "对不上的存档删掉")
        _ = await undoInEditor(renderer)
        #expect(await editorText(renderer) == "changed by agent\n", "没有可撤的，正文不动")
    }
}

/// 删除进废纸篓时存档跟着进去，撤销删除时带回来；只看过没改的不占存档。不起 WebView：编辑与历史都是伪造的，会话不当「当前」。
@Test @MainActor func storedUndoHistoryFollowsDeleteAndUndoDelete() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        let other = project.appendingPathComponent("seen.txt")
        try "seen\n".write(to: other, atomically: true, encoding: .utf8)
        let store = EditorHistoryStore(directory: directory.appendingPathComponent("undo"))
        let session = ProjectSession(root: project, git: nil, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!),
                                     editorHistories: store)
        defer { session.tearDown() }

        let edits = #"{"done":[{"changes":[{"from":{"line":0,"ch":0},"to":{"line":0,"ch":0},"text":["v2"]}]}],"undone":[]}"#
        session.openFile(other, pinned: true)
        session.applyEditorHistory(path: try #require(session.activeTab.flatMap(session.documentURL(for:))).path, text: "seen\n",
                                   history: #"{"done":[{"ranges":[]}],"undone":[]}"#)
        session.openFile(file, pinned: true)
        let tab = try #require(session.activeTab)
        let path = try #require(session.documentURL(for: tab)).path
        session.applyEdit(path: path, text: "v2\n")
        session.applyEditorHistory(path: path, text: "v2\n", history: edits)
        // 历史对应的不是磁盘上的那份（草稿还没写）：不存
        session.storeEditorHistories()
        #expect(store.entries[path] == nil)
        session.closeAllTabs()
        #expect(session.tabs.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "v2\n")
        #expect(Set(store.entries.keys) == [path], "写完盘才存；只看过的 seen.txt 不存")

        session.delete(FileNode(url: file, name: "a.txt", isDirectory: false))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.entries[path] == nil, "原路径上不再有")
        #expect(store.entries.count == 1, "跟着进了废纸篓")

        session.undo()
        await waitUntil { FileManager.default.fileExists(atPath: file.path) && store.entries[path] != nil }
        #expect(store.entries[path]?.textHash == TextFingerprint.of("v2\n"), "撤销删除带回来")
        #expect(store.load(path: path, textHash: TextFingerprint.of("v2\n")) == edits)
    }
}
