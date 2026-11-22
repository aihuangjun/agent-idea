import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

/// `active` 传 false 就是「这个项目不是当前项目」：**用 `applyEdit` 伪造编辑、又要断言磁盘内容的用例传 false**。
/// 当前会话的 ⌘S / 关标签会先向 WebView 要一次编辑器里的最新文字（真实场景里编辑器才是文字的源头），
/// 伪造的编辑页面并不知道，WebView 恰好在这几拍里加载完就会用页面里的旧文字把草稿盖回去。
@MainActor
private func makeSession(in directory: URL, git: FakeCommandRunner? = nil, active: Bool = true) -> ProjectSession {
    let client = git.map { GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: $0) }
    let session = ProjectSession(root: directory, git: client, renderer: ContentRenderer(),
                                 preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
    session.setActive(active)
    return session
}

@MainActor
/// 等条件成立。超时给得宽（测试是并行跑的，几十个 WKWebView / 离屏窗口一起挤主线程时
/// 一次 git 探测排上几秒很正常）——条件一成立就返回，通过的用例不会因此变慢。
private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// 编辑：改动记成草稿并把预览标签固定；保存按原来的行尾写回；与磁盘一致就不算改动；关标签自动保存。
@Test @MainActor func editsBecomeDraftsAndSaveKeepsLineEndings() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt")
        try "one\r\ntwo\r\n".write(to: file, atomically: true, encoding: .utf8)
        // 编辑是伪造的（applyEdit）而这条用例要断言磁盘上的内容：会话不当「当前」，见 makeSession 的说明
        let session = makeSession(in: directory, active: false)
        session.openFile(file, pinned: false)
        let tab = try #require(session.activeTab)
        #expect(session.isEditable(tab) && !session.isModified(tab))

        session.applyEdit(path: file.path, text: "one\ntwo\nthree\n")
        #expect(session.isModified(tab))
        #expect(session.tabs[0].isPreview == false, "一改就固定，免得被下一次单击顶掉")
        // 改回原样：不算改动
        session.applyEdit(path: file.path, text: "one\ntwo\n")
        #expect(!session.isModified(tab))

        session.applyEdit(path: file.path, text: "one\ntwo\nthree\n")
        session.saveActiveTab()
        await waitUntil { !session.isModified(tab) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\r\ntwo\r\nthree\r\n", "行尾保持 CRLF")
        #expect(session.contents[tab.id]?.text == "one\r\ntwo\r\nthree\r\n", "内容里存磁盘上的样子")
        if case .code(_, _, _, let lines, let modified) = session.contents[tab.id] { #expect(lines == 3 && modified != nil) } else { Issue.record("应是代码内容") }

        // 关掉一个改过的标签：先写回磁盘再关
        session.applyEdit(path: file.path, text: "final\n")
        session.closeTab(tab.id)
        await waitUntil { session.tabs.isEmpty }
        #expect(try String(contentsOf: file, encoding: .utf8) == "final\r\n")
        #expect(session.drafts.isEmpty)
    }
}

/// 磁盘上变了：没改过的重读；改过的留着草稿，标题条能看出磁盘更新了。
@Test @MainActor func draftsSurviveDiskChanges() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        let session = makeSession(in: directory)
        session.openFile(file, pinned: true)
        let tab = try #require(session.activeTab)
        session.applyEdit(path: file.path, text: "mine")

        try "v2".write(to: file, atomically: true, encoding: .utf8)
        // 把修改时间往后拨，避免与 v1 落在同一秒
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        session.refreshAll()
        #expect(session.drafts[tab.id] == "mine")
        #expect(session.isDiskNewer(tab))
        // 保存：用户的版本覆盖磁盘
        session.saveActiveTab()
        await waitUntil { session.drafts.isEmpty }
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
        #expect(!session.isDiskNewer(tab))
    }
}

/// 太大的文件只读。
@Test @MainActor func hugeFilesAreReadOnly() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("big.txt")
        try String(repeating: "x", count: DraftStore.editableLimit + 1).write(to: file, atomically: true, encoding: .utf8)
        let session = makeSession(in: directory)
        session.openFile(file, pinned: true)
        await waitUntil { session.activeContent != .loading }
        let tab = try #require(session.activeTab)
        #expect(!session.isEditable(tab))
        session.applyEdit(path: file.path, text: "y")
        #expect(!session.isModified(tab), "不可编辑的标签不接受改动")
    }
}

/// 删除文件后关标签：草稿丢弃，不能把刚进废纸篓的文件又写回来。
@Test @MainActor func deletingFileDiscardsDraftInsteadOfResurrecting() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        let session = makeSession(in: directory)
        session.openFile(file, pinned: true)
        session.applyEdit(path: file.path, text: "edited")
        let node = try #require(session.rows.first { $0.node.name == "a.txt" }?.node)
        session.delete(node)
        #expect(session.tabs.isEmpty && session.drafts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// 渲染器的 edited 消息接到当前会话；关项目时草稿写回磁盘。
@Test @MainActor func workbenchRoutesEditsAndSavesOnClose() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        let workbench = WorkbenchModel(git: nil, defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!, recentFile: directory.appendingPathComponent("recent.json"))
        workbench.openProject(file)
        let session = try #require(workbench.active)
        let tab = try #require(session.activeTab)
        workbench.renderer.onEdited?(file.path, "from editor")
        #expect(session.isModified(tab))
        workbench.closeProject()
        #expect(try String(contentsOf: file, encoding: .utf8) == "from editor")
    }
}

/// DraftStore 的规则本身。
@Test func draftStoreRules() throws {
    try withTemporaryDirectory { directory in
        var store = DraftStore()
        let content = TabContent.code(text: "a\r\nb\r\n", language: .plainText, encoding: "UTF-8", lineCount: 2, modified: nil)
        #expect(DraftStore.isEditable(content))
        #expect(!DraftStore.isEditable(.image(url: directory, sizeBytes: 1)))
        #expect(!DraftStore.isEditable(.code(text: String(repeating: "x", count: DraftStore.editableLimit + 1), language: .plainText, encoding: "UTF-8", lineCount: 1, modified: nil)))

        #expect(store.apply(text: "a\nb\n", to: "t", saved: "a\r\nb\r\n") == false, "行尾不同不算改动")
        #expect(store.apply(text: "a\nc\n", to: "t", saved: "a\r\nb\r\n") == true)
        #expect(store.isModified("t") && store["t"] == "a\nc\n")

        let url = directory.appendingPathComponent("t.txt")
        let saved = try #require(try store.write("t", to: url, content: content))
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\r\nc\r\n")
        #expect(saved.text == "a\r\nc\r\n" && saved.modificationDate != nil && !store.isModified("t"))
        #expect(try store.write("t", to: url, content: saved) == nil, "没有草稿什么都不写")
        #expect(!DraftStore.isDiskNewer(at: url, than: saved.modificationDate))
        #expect(DraftStore.isDiskNewer(at: url, than: Date(timeIntervalSince1970: 0)))

        store.apply(text: "x", to: "t", saved: "")
        store.discard("t")
        #expect(store.isEmpty)
    }
}

/// 打开文件时取 HEAD 里的内容当变更标记的基线；HEAD 变了重取；HEAD 里没有的文件没有基线。
@Test @MainActor func baseTextFollowsHead() async throws {
    try await withTemporaryDirectory { directory in
        let tracked = directory.appendingPathComponent("t.txt")
        let fresh = directory.appendingPathComponent("n.txt")
        try "v2".write(to: tracked, atomically: true, encoding: .utf8)
        try "new".write(to: fresh, atomically: true, encoding: .utf8)
        let head = Locked("aaa")
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path + "\n")
            case "rev-parse": return shellOutput(head.value)
            case "status": return shellOutput("# branch.oid \(head.value)\u{0}# branch.head main\u{0}")
            case "show" where arguments.last == "HEAD:t.txt": return shellOutput("v1@\(head.value)")
            case "show": return ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: path 'n.txt' does not exist in 'HEAD'")
            default: return shellOutput("")
            }
        }
        let session = makeSession(in: directory, git: runner)
        await waitUntil { session.gitSnapshot.branch.headOID == "aaa" }
        session.openFile(tracked, pinned: true)
        session.openFile(fresh, pinned: true)
        let trackedTab = EditorTab.id(forFile: tracked), freshTab = EditorTab.id(forFile: fresh)
        await waitUntil { session.baseTexts[trackedTab] != nil && runner.calls(startingWith: "show").count >= 2 }
        #expect(session.baseTexts[trackedTab] == "v1@aaa")
        #expect(session.baseTexts[freshTab] == nil)

        head.value = "bbb"
        session.refreshGit()
        await waitUntil { session.baseTexts[trackedTab] == "v1@bbb" }
        session.closeTab(trackedTab)
        await waitUntil { session.baseTexts[trackedTab] == nil }
    }
}

/// 后退 / 前进像浏览器：按打开顺序回退，中途打开新标签作废「前进」，关掉的标签从历史里消失。
@Test @MainActor func backAndForwardWalkTabHistory() async throws {
    try await withTemporaryDirectory { directory in
        let files = try ["a", "b", "c", "d"].map { name -> URL in
            let url = directory.appendingPathComponent("\(name).txt")
            try name.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let session = makeSession(in: directory)
        #expect(!session.canGoBack && !session.canGoForward)
        for url in files.prefix(3) { session.openFile(url, pinned: true) }
        #expect(session.activeTab?.title == "c.txt" && session.canGoBack && !session.canGoForward)

        session.goBack()
        #expect(session.activeTab?.title == "b.txt" && session.canGoForward)
        session.goBack()
        #expect(session.activeTab?.title == "a.txt" && !session.canGoBack)
        session.goForward()
        #expect(session.activeTab?.title == "b.txt")
        // 从中间去新地方：前进作废
        session.openFile(files[3], pinned: true)
        #expect(session.activeTab?.title == "d.txt" && !session.canGoForward)
        #expect(session.navigation.entries.map(\.tabID) == [files[0], files[1], files[3]].map {
            EditorTab.id(forFile: $0.resolvingSymlinksInPath().standardizedFileURL)
        })
        // 点标签切换也记进历史；关掉的标签抹掉
        session.activate(EditorTab.id(forFile: files[2]))
        session.closeTab(EditorTab.id(forFile: files[1]))
        await waitUntil { session.tabs.count == 3 }
        #expect(!session.navigation.entries.contains { $0.tabID.hasSuffix("/b.txt") })
        session.goBack()
        #expect(session.activeTab?.title == "d.txt")
        session.goBack()
        #expect(session.activeTab?.title == "a.txt")
    }
}

@Test @MainActor func arbitraryComparisonOpensReadOnlyDiffWithoutGit() async throws {
    try await withTemporaryDirectory { root in
        let a = root.appendingPathComponent("A.swift"), b = root.appendingPathComponent("B.swift")
        try "let value = 1\n".write(to: a, atomically: true, encoding: .utf8)
        try "let value = 2\n".write(to: b, atomically: true, encoding: .utf8)
        let session = makeSession(in: root)
        session.compareFiles(a, b)
        await waitUntil { session.activeTab?.comparison != nil }
        let tab = try #require(session.activeTab)
        #expect(tab.comparison?.left == "A.swift" && tab.comparison?.right == "B.swift")
        #expect(tab.isDiff && tab.diffChange == nil && session.documentID(for: tab) == nil)
        #expect(session.supportsDiffReading && session.canNavigateChanges && !session.isEditable(tab))
        #expect(session.diffReviewProgress.fileCount == 0)
        let content = try #require(session.activeContent)
        guard case .diff(_, _, _, _, _, let edit) = content.renderContent(for: tab, diffMode: .sideBySide) else {
            Issue.record("Expected a rendered text comparison")
            return
        }
        #expect(edit?.readOnly == true && edit?.oldText.contains("= 1") == true && edit?.newText.contains("= 2") == true)
        #expect(edit?.displayPath == "B.swift")
    }
}

@Test @MainActor func sourceNavigationRestoresDifferentLocationsInTheSameFile() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("One.java")
        try "class One {\n    int first;\n    int second;\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let session = makeSession(in: directory)
        let editor = session.renderer
        var didRender = false
        editor.onRendered = { kind, _ in if kind == "code" { didRender = true } }
        session.openFile(file, pinned: true)
        await waitUntil { didRender }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setCursor(1, 8)")
        session.goToLine(SourceLocation(line: 3, column: 9))
        await waitUntil { session.navigation.entries.first?.position == EditorCursor(line: 1, ch: 8) }
        #expect(session.navigation.entries.count == 2)
        #expect(session.canGoBack)
        session.goBack()
        let back = try await editor.webView.evaluateJavaScript("window.ide.sourceCursor().line") as? Int
        #expect(back == 1)
        session.goForward()
        let forward = try await editor.webView.evaluateJavaScript("window.ide.sourceCursor().line") as? Int
        #expect(forward == 2)
        session.showRecentLocations()
        #expect(session.sourceNavigation?.entries.count == 2)
        session.sourceNavigation = nil
        session.showFileStructure()
        await waitUntil { session.sourceNavigation != nil }
        #expect(session.sourceNavigation?.entries.map(\.title) == ["One", "first", "second"])
    }
}

@Test @MainActor func fileReplacementRespectsCapturedSelectionAndAdvancesPastItsOwnOutput() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("edit.txt")
        try "token token\ntoken\n".write(to: file, atomically: true, encoding: .utf8)
        let session = makeSession(in: directory)
        let renderer = session.renderer
        var didRender = false
        renderer.onRendered = { kind, _ in if kind == "code" { didRender = true } }
        renderer.onEditLocation = { [weak session] path, position in session?.editorDidChange(at: position, path: path) }
        session.openFile(file, pinned: true)
        await waitUntil { didRender }
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setSelection({line:0,ch:0},{line:0,ch:11})")
        session.showFileReplace()
        await waitUntil { session.fileReplace?.inSelection == true }
        let replace = try #require(session.fileReplace)
        replace.query = "token"
        replace.replacement = "token!"
        await replace.replace(all: false, using: renderer)
        await replace.replace(all: false, using: renderer)
        let state = try await renderer.editableSnapshot(path: replace.path)
        #expect(state?.text == "token! token!\ntoken\n")
        #expect(session.lastEditLocation?.location?.line == 1)
        #expect(session.lastEditLocation?.location?.column == 8)
    }
}

/// 历史里回滚一个变更：反向 apply，结果显示在面板上，随后刷新 git 状态。
@Test @MainActor func revertingHistoryChangeAppliesReversePatch() async throws {
    try await withTemporaryDirectory { directory in
        let statusCalls = Locked(0)
        let applyFails = Locked(false)
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path + "\n")
            case "rev-parse": return shellOutput("abc")
            case "status":
                statusCalls.value += 1
                return shellOutput("# branch.oid abc\u{0}# branch.head main\u{0}")
            case "diff": return shellOutput("diff --git a/x b/x\n")
            case "apply": return applyFails.value ? ShellOutput(status: 1, standardOutput: Data(), standardError: "error: patch failed: x:1") : shellOutput("")
            default: return shellOutput("")
            }
        }
        let session = makeSession(in: directory, git: runner)
        await waitUntil { session.history != nil }
        let history = try #require(session.history)
        let commit = GitCommit(hash: "abc", shortHash: "abc", parents: ["p"], authorName: "", authorEmail: "", authorDate: Date(), subject: "s", body: "")
        let change = GitChange(path: "x", kind: .modified)
        await waitUntil { statusCalls.value >= 1 }
        let before = statusCalls.value

        history.revert(change, in: commit)
        await waitUntil { history.status != nil }
        if case .success(let text) = history.status { #expect(text.contains("已回滚 x")) } else { Issue.record("应成功：\(String(describing: history.status))") }
        #expect(runner.calls(startingWith: "apply").first?.prefix(2) == ["apply", "--reverse"])
        await waitUntil { statusCalls.value > before }

        applyFails.value = true
        history.revert(change, in: commit)
        await waitUntil { if case .failure = history.status { return true } else { return false } }
        if case .failure(let text) = history.status { #expect(text.contains("patch failed")) }
        history.dismissStatus()
        #expect(history.status == nil)
    }
}
