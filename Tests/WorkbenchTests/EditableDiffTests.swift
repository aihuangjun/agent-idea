import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@preconcurrency import WebKit
@testable import Workbench

@MainActor
/// 等条件成立。超时给得宽（测试是并行跑的，几十个 WKWebView / 离屏窗口一起挤主线程时
/// 一次 git 探测排上几秒很正常）——条件一成立就返回，通过的用例不会因此变慢。
private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// 一个有仓库的会话：status 报 m.txt 修改、n.txt 未跟踪、gone.txt 已删除；HEAD 里 m.txt 是 v1。
///
/// `active` 传 false 就是「这个项目不是当前项目」：**用 `applyEdit` 伪造编辑的用例要传 false**。
/// 当前会话的 ⌘S / 关标签会先向 WebView 要一次编辑器里的最新文字（真实场景里编辑器才是文字的源头），
/// 而伪造的编辑页面并不知道；WebView 恰好在这几拍里加载完，就会拿页面里的旧文字把刚写的草稿盖回去——
/// 表现为「保存后磁盘上应该是 v4」偶发失败。草稿、落盘、标签生命周期都是模型这一层的事，与渲染无关。
@MainActor
private func makeSession(in directory: URL, active: Bool = true, renderer: ContentRenderer? = nil) -> (ProjectSession, FakeCommandRunner) {
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
    let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: renderer ?? ContentRenderer(),
                                 preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
    session.setActive(active)
    return (session, runner)
}

@Test @MainActor func refreshingGitAlsoReloadsTheOpenEditableDiffDocument() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        let renderer = ContentRenderer()
        let painted = Locked(false)
        renderer.onRendered = { kind, _ in if kind == "diff" { painted.value = true } }
        let (session, _) = makeSession(in: directory, renderer: renderer)
        defer { session.tearDown() }
        await waitUntil { session.changeGroups.total == 3 }
        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        session.openDiff(change, pinned: true)
        let tab = try #require(session.activeTab)
        let documentID = try #require(session.documentID(for: tab))
        await waitUntil { session.contents[tab.id] == .editableDiff(documentID: documentID) }
        await waitUntil { painted.value }
        try "changed by terminal\n".write(to: file, atomically: true, encoding: .utf8)
        session.refreshGit()
        await waitUntil { session.contents[documentID]?.text == "changed by terminal\n" }
        #expect(session.contents[documentID]?.text == "changed by terminal\n")
        #expect(session.drafts.isEmpty)

        // 手动刷新也能识别保留了 mtime 的写入。
        let modified = try #require(session.contents[documentID]?.modificationDate)
        try "same timestamp\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        session.refreshAll()
        session.refreshAll()
        await waitUntil { session.contents[documentID]?.text == "same timestamp\n" }
        let state = await withCheckedContinuation { continuation in renderer.currentState { continuation.resume(returning: $0) } }
        #expect(session.contents[documentID]?.text == "same timestamp\n")
        #expect(state.text == "same timestamp\n")
        #expect(session.drafts.isEmpty, "重复刷新不能把旧页面当成新的未保存草稿")
    }
}

@Test @MainActor func replacingAPreviewDuringRefreshDoesNotBlockLaterDocumentReloads() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        let renderer = ContentRenderer()
        let painted = Locked(false)
        renderer.onRendered = { kind, _ in if kind == "diff" { painted.value = true } }
        let (session, _) = makeSession(in: directory, renderer: renderer)
        defer { session.tearDown() }
        await waitUntil { session.changeGroups.total == 3 }
        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        let deleted = try #require(session.gitSnapshot.changes.first { $0.path == "gone.txt" })
        session.openFile(file, pinned: true)
        session.openDiff(change)
        await waitUntil { painted.value }
        let documentID = try #require(session.activeTab.flatMap(session.documentID(for:)))
        session.refreshAll()
        // 原 diff 的异步 getState 尚未返回，预览已被替换；同文件的固定标签仍然保留。
        session.openDiff(deleted)
        let replaced = await withCheckedContinuation { continuation in renderer.currentState { continuation.resume(returning: $0) } }
        #expect(replaced.kind != nil)
        try "after preview replacement\n".write(to: file, atomically: true, encoding: .utf8)
        session.openFile(file, pinned: true)
        session.refreshAll()
        await waitUntil { session.contents[documentID]?.text == "after preview replacement\n" }
        #expect(session.contents[documentID]?.text == "after preview replacement\n")
        #expect(session.drafts.isEmpty)
    }
}

@Test @MainActor func htmlFileSwitchesBetweenPreviewAndEditableSource() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("page.HTML")
        try "<h1>hello</h1>".write(to: file, atomically: true, encoding: .utf8)
        let (session, _) = makeSession(in: directory, active: false)
        defer { session.tearDown() }
        session.openFile(file, pinned: true)
        let tab = try #require(session.activeTab)
        let content = try #require(session.activeContent)
        #expect(content.renderContent(for: tab, diffMode: .sideBySide).kindName == "html")
        session.setHTMLView(.source)
        await waitUntil { session.activeTab?.htmlView == .source }
        let source = try #require(session.activeTab)
        #expect(content.renderContent(for: source, diffMode: .sideBySide, editable: true).kindName == "code")
        session.applyEdit(path: file.path, text: "<h1>draft</h1>")
        session.setHTMLView(.preview)
        await waitUntil { session.activeTab?.htmlView == .preview }
        let preview = try #require(session.activeTab)
        #expect(content.renderContent(for: preview, diffMode: .sideBySide, draft: session.drafts[tab.id]) == .html(path: file.path, text: "<h1>draft</h1>", documentDirectory: file.deletingLastPathComponent()))
    }
}

@Test @MainActor func refreshingHTMLReloadsResourcesWhilePreservingTheDraftAndSourceEdits() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("page.htm")
        let style = directory.appendingPathComponent("style.css")
        try "<h1>disk</h1>".write(to: file, atomically: true, encoding: .utf8)
        try "h1 { color: rgb(12, 34, 56); }".write(to: style, atomically: true, encoding: .utf8)
        let renderer = ContentRenderer()
        let (session, _) = makeSession(in: directory, active: false, renderer: renderer)
        defer { session.tearDown() }
        session.openFile(file, pinned: true)
        let draft = "<link rel='stylesheet' href='/style.css'><h1>draft</h1>"
        session.applyEdit(path: file.path, text: draft)
        var htmlRenders = 0, sourceRendered = false
        renderer.onRendered = { kind, _ in
            if kind == "html" { htmlRenders += 1 }
            if kind == "code" { sourceRendered = true }
        }
        session.setActive(true)
        await waitUntil { htmlRenders > 0 }
        #expect(htmlRenders > 0)
        try "h1 { color: rgb(65, 43, 21); }".write(to: style, atomically: true, encoding: .utf8)
        let beforeRefresh = htmlRenders
        session.refreshAll()
        await waitUntil { htmlRenders > beforeRefresh }
        #expect(htmlRenders > beforeRefresh)
        let result = try await renderer.displayedWebView.evaluateJavaScript("[document.querySelector('h1').textContent, getComputedStyle(document.querySelector('h1')).color].join('|')") as? String
        #expect(result == "draft|rgb(65, 43, 21)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "<h1>disk</h1>")
        #expect(session.drafts[EditorTab.id(forFile: file)] == draft)

        session.setHTMLView(.source)
        await waitUntil { sourceRendered }
        #expect(sourceRendered)
        let newDraft = "<h1>latest editor text</h1>"
        _ = try await renderer.webView.callAsyncJavaScript("document.querySelector('.CodeMirror').CodeMirror.setValue(text)", arguments: ["text": newDraft], in: nil, in: .page)
        let beforeSwitch = htmlRenders
        // 不等 edited 消息的去抖：切视图必须先向编辑器收取最新文字。
        session.setHTMLView(.preview)
        await waitUntil { htmlRenders > beforeSwitch }
        #expect(htmlRenders > beforeSwitch)
        #expect(try await renderer.displayedWebView.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "latest editor text")
        #expect(session.drafts[EditorTab.id(forFile: file)] == newDraft)
    }
}

@Test @MainActor func rollbackKeepsDraftInUndoAndDoesNotSaveOldEditorOverRestoredFile() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "working copy".write(to: file, atomically: true, encoding: .utf8)
        let restored = Locked(false)
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path)
            case "status": return shellOutput("# branch.oid abc\u{0}# branch.head main\u{0}" + (restored.value ? "" : "1 .M N... 100644 100644 100644 a b m.txt\u{0}"))
            case "show": return shellOutput("HEAD version")
            case "restore":
                try? "HEAD version".write(to: file, atomically: true, encoding: .utf8)
                restored.value = true
                return shellOutput("")
            default: return shellOutput("")
            }
        }
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: ContentRenderer(), preferences: ReadingPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        defer { session.tearDown() }
        await waitUntil { session.changeGroups.total == 1 }
        let change = try #require(session.gitSnapshot.changes.first)
        session.openFile(file, pinned: true)
        session.openDiff(change, pinned: true)
        await waitUntil { session.activeContent != .loading }
        // 非当前会话，伪造的编辑不会被 WebView 的旧文本盖掉。
        session.applyEdit(path: file.path, text: "unsaved draft")
        session.rollback([change])
        await waitUntil { session.canUndo && session.tabs.isEmpty }
        #expect(try String(contentsOf: file, encoding: .utf8) == "HEAD version")
        #expect(session.drafts.isEmpty)
        session.undo()
        await waitUntil { session.canRedo && !session.isUndoing }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unsaved draft")
    }
}

@Test @MainActor func preparingRollbackBlocksConcurrentRepositoryWrites() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        let renderer = ContentRenderer()
        let painted = Locked(false)
        renderer.onRendered = { kind, _ in if kind == "diff" { painted.value = true } }
        let (session, runner) = makeSession(in: directory, renderer: renderer)
        defer { session.tearDown() }
        await waitUntil { session.changeGroups.total == 3 }
        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        session.openDiff(change, pinned: true)
        await waitUntil { painted.value && session.activeTab.map(session.isEditable) == true }
        let commit = try #require(session.commit)
        #expect(session.activeTab.map(session.isEditable) == true)
        commit.message = "must not commit during rollback"
        #expect(commit.canCommit && commit.canPush && session.canSwitchBranch)
        session.rollback([change])
        #expect(commit.isPreparingRollback)
        #expect(!commit.canCommit && !commit.canPush && !commit.canRollback)
        #expect(!session.canSwitchBranch && !session.needsUpstreamChoice)
        session.rollback([change])
        commit.commit(push: false)
        commit.pushCurrentBranch()
        session.syncWithRemote()
        session.trackUpstream("origin/main")
        session.pushSettingUpstream(to: "origin")
        session.createBranch(named: "other", from: "main")
        await waitUntil { session.canUndo && !session.isRollingBack }
        #expect(session.canUndo && !session.isRollingBack)
        #expect(runner.calls(startingWith: "restore").count == 1)
        for command in ["commit", "push", "fetch", "switch", "branch"] {
            #expect(runner.calls(startingWith: command).isEmpty, "回滚期间不应执行 \(command)")
        }
        #expect(commit.canPush && session.canSwitchBranch)
    }
}

@Test @MainActor func revertContextActionDirectlyRollsBackSelectedTrackedFiles() async throws {
    try await withTemporaryDirectory { directory in
        try "working copy".write(to: directory.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        let (session, runner) = makeSession(in: directory, active: false)
        defer { session.tearDown() }
        await waitUntil { session.changeGroups.total == 3 }
        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        #expect(session.rollbackMenuAction(for: change)?.title == "回滚")
        session.selectChange("m.txt")
        let order = session.gitSnapshot.changes.map(\.path)
        session.toggleChangeSelection("gone.txt", order: order)
        session.toggleChangeSelection("n.txt", order: order)
        let action = try #require(session.rollbackMenuAction(for: change))
        #expect(action.title == "回滚 2 个文件")
        action.perform()
        await waitUntil { !runner.calls(startingWith: "restore").isEmpty }
        #expect(runner.calls(startingWith: "restore").first == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "gone.txt", "m.txt"])
        session.selectChange("n.txt")
        let untracked = try #require(session.gitSnapshot.changes.first { $0.path == "n.txt" })
        #expect(session.rollbackMenuAction(for: untracked) == nil)
    }
}

@Test @MainActor func diffTabReturnsToTheUsersPositionAfterItsInitialReveal() async throws {
    try await withTemporaryDirectory { directory in
        let old = (0..<700).map { "line \($0)" }.joined(separator: "\n")
        let file = directory.appendingPathComponent("m.txt")
        try old.replacingOccurrences(of: "line 400", with: "FIRST DIFFERENCE").write(to: file, atomically: true, encoding: .utf8)
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path)
            case "status": return shellOutput("# branch.oid abc\u{0}# branch.head main\u{0}1 .M N... 100644 100644 100644 a b m.txt\u{0}")
            case "show": return shellOutput(old)
            default: return shellOutput("")
            }
        }
        let renderer = ContentRenderer()
        var rendered = 0
        renderer.onRendered = { _, _ in rendered += 1 }
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: renderer,
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        session.setActive(true)
        defer { session.tearDown() }
        await waitUntil { session.changeGroups.total == 1 }
        session.openDiff(try #require(session.gitSnapshot.changes.first), pinned: true)
        let id = try #require(session.activeTabID)
        await waitUntil { session.activeContent != .loading && rendered > 0 }
        let initial = await withCheckedContinuation { continuation in renderer.currentState { continuation.resume(returning: $0) } }
        #expect(initial.cursor?.line == 400)
        _ = try await renderer.webView.evaluateJavaScript("(() => { const cm = document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror; cm.setCursor({line: 10, ch: 2}); cm.scrollTo(null, 0); return true; })()")
        session.openFile(file, pinned: true)
        await waitUntil { session.tabs.first(where: { $0.id == id })?.hasDiffPosition == true }
        let previous = rendered
        session.activate(id)
        await waitUntil { rendered > previous }
        let restored = await withCheckedContinuation { continuation in renderer.currentState { continuation.resume(returning: $0) } }
        #expect(restored.cursor == EditorCursor(line: 10, ch: 2))
        #expect(restored.scrollTop == 0)
    }
}

/// 工作区变更的 diff 标签可以编辑：文档与基线加载好，改动记到文件的草稿上，文件标签与 diff 标签看到的是同一份。
@Test @MainActor func workingCopyDiffIsEditableAndSharesTheDocument() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        // 编辑是伪造的（applyEdit），所以会话不当「当前」：见 makeSession 的说明
        let (session, _) = makeSession(in: directory, active: false)
        await waitUntil { session.changeGroups.total == 3 }
        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })

        session.openDiff(change, pinned: true)
        let diffTab = try #require(session.activeTab)
        await waitUntil { session.contents[diffTab.id] != .loading && session.contents[diffTab.id] != nil }
        let documentID = try #require(session.documentID(for: diffTab))
        #expect(session.contents[diffTab.id] == .editableDiff(documentID: documentID))
        #expect(session.contents[documentID]?.text == "v2\n")
        #expect(session.baseTexts[documentID] == "v1\n")
        #expect(session.isEditable(diffTab) && !session.isModified(diffTab))

        // 编辑器（画的是 diff 右边）发来改动：草稿挂在文档上，两种标签都显示「已修改」
        session.applyEdit(path: file.path, text: "v3\n")
        #expect(session.isModified(diffTab))
        session.openFile(file, pinned: true)
        let fileTab = try #require(session.activeTab)
        #expect(fileTab.id == documentID && session.isModified(fileTab))
        #expect(session.drafts.count == 1)

        // 关掉文件标签：关标签就保存（IDEA 的做法），文档本身还被 diff 标签用着、留着
        session.closeTab(fileTab.id)
        await waitUntil { session.tabs.count == 1 && session.drafts.isEmpty }
        #expect(try String(contentsOf: file, encoding: .utf8) == "v3\n")
        #expect(session.contents[documentID]?.text == "v3\n" && !session.isModified(diffTab))
        // 在 diff 标签里接着改，⌘S 保存
        session.activate(diffTab.id)
        session.applyEdit(path: file.path, text: "v4\n")
        #expect(session.isModified(diffTab))
        session.saveActiveTab()
        await waitUntil { session.drafts.isEmpty }
        #expect(session.drafts.isEmpty, "⌘S 之后草稿应该已经落盘")
        #expect(try String(contentsOf: file, encoding: .utf8) == "v4\n")

        // 最后一个用文档的标签关掉：文档、基线一起释放
        session.closeTab(diffTab.id)
        await waitUntil { session.tabs.isEmpty }
        #expect(session.contents[documentID] == nil && session.baseTexts[documentID] == nil)
    }
}

/// 变更列表里删除文件时，可编辑 diff 标签的草稿必须丢弃，不能把刚进废纸篓的文件写回来。
@Test @MainActor func deletingFromChangesDiscardsDiffTabDraft() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        // 同样是伪造的编辑，同样不当「当前」
        let (session, _) = makeSession(in: directory, active: false)
        await waitUntil { session.changeGroups.total == 3 }
        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        session.openDiff(change, pinned: true)
        let diffTab = try #require(session.activeTab)
        await waitUntil { session.contents[diffTab.id] != .loading && session.contents[diffTab.id] != nil }
        session.applyEdit(path: file.path, text: "edited\n")
        #expect(session.isModified(diffTab))

        try #require(session.commit).delete(change)
        await waitUntil { session.tabs.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: file.path), "文件不能被草稿写回来")
        #expect(session.drafts.isEmpty)
    }
}

/// 未跟踪文件也能在 diff 里改（基线是空）；已删除的文件没有可编辑的 diff，走静态视图。
@Test @MainActor func untrackedIsEditableButDeletedIsStatic() async throws {
    try await withTemporaryDirectory { directory in
        try "new\n".write(to: directory.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let (session, _) = makeSession(in: directory)
        await waitUntil { session.changeGroups.total == 3 }
        let untracked = try #require(session.gitSnapshot.changes.first { $0.path == "n.txt" })
        let deleted = try #require(session.gitSnapshot.changes.first { $0.path == "gone.txt" })

        session.openDiff(untracked, pinned: true)
        let untrackedTab = try #require(session.activeTab)
        await waitUntil { session.contents[untrackedTab.id] != .loading && session.contents[untrackedTab.id] != nil }
        let documentID = try #require(session.documentID(for: untrackedTab))
        #expect(session.contents[untrackedTab.id] == .editableDiff(documentID: documentID))
        #expect(session.baseTexts[documentID] == nil, "HEAD 里没有：基线为空")

        session.openDiff(deleted, pinned: true)
        let deletedTab = try #require(session.activeTab)
        await waitUntil { session.contents[deletedTab.id] != .loading && session.contents[deletedTab.id] != nil }
        #expect(session.documentID(for: deletedTab) == nil && !session.isEditable(deletedTab))
        if case .diff = session.contents[deletedTab.id] {} else { Issue.record("已删除的应是静态 diff：\(String(describing: session.contents[deletedTab.id]))") }
    }
}

/// F7 / ⇧F7 与标题条的上下箭头只在有变更点可跳的标签上有效：diff 标签、有工作区变更的文本标签；没变更的文件不行。
@Test @MainActor func changeNavigationIsOfferedOnDiffsAndChangedFiles() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        let clean = directory.appendingPathComponent("clean.txt")
        try "same\n".write(to: clean, atomically: true, encoding: .utf8)
        let (session, _) = makeSession(in: directory)
        await waitUntil { session.changeGroups.total == 3 }
        #expect(!session.canNavigateChanges)

        let change = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        session.openDiff(change, pinned: true)
        #expect(session.canNavigateChanges)

        session.openFile(file, pinned: true)
        await waitUntil { session.activeContent?.text != nil }
        #expect(session.canNavigateChanges)

        session.openFile(clean, pinned: true)
        await waitUntil { session.activeContent?.text != nil }
        #expect(!session.canNavigateChanges)
    }
}

/// 变更列表里单击另一条，预览标签被顶掉：它指着的文档也要放掉。否则文件在没人看着的时候被 Agent 改了，
/// 再点回来时 diff 用的是内存里那份旧内容——与 HEAD 一样就一行变更都没有（1.2.5 修的）。
@Test @MainActor func replacedPreviewDiffReleasesItsDocument() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        try "n\n".write(to: directory.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let (session, _) = makeSession(in: directory, active: false)
        await waitUntil { session.changeGroups.total == 3 }
        let modified = try #require(session.gitSnapshot.changes.first { $0.path == "m.txt" })
        let untracked = try #require(session.gitSnapshot.changes.first { $0.path == "n.txt" })

        session.openDiff(modified)
        let documentID = try #require(session.activeTab.flatMap(session.documentID(for:)))
        await waitUntil { session.contents[session.activeTabID!] == .editableDiff(documentID: documentID) }
        #expect(session.contents[documentID]?.text == "v1\n")

        session.openDiff(untracked)
        #expect(session.tabs.count == 1)
        #expect(session.contents[documentID] == nil && session.baseTexts[documentID] == nil)

        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        session.openDiff(modified)
        await waitUntil { session.contents[session.activeTabID!] == .editableDiff(documentID: documentID) }
        #expect(session.contents[documentID]?.text == "v2\n")
        #expect(session.baseTexts[documentID] == "v1\n")
    }
}
