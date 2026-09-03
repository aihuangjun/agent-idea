import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// 一个有仓库的会话：status 报 m.txt 修改、n.txt 未跟踪、gone.txt 已删除；HEAD 里 m.txt 是 v1。
@MainActor
private func makeSession(in directory: URL) -> (ProjectSession, FakeCommandRunner) {
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
    return (session, runner)
}

/// 工作区变更的 diff 标签可以编辑：文档与基线加载好，改动记到文件的草稿上，文件标签与 diff 标签看到的是同一份。
@Test @MainActor func workingCopyDiffIsEditableAndSharesTheDocument() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("m.txt")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        let (session, _) = makeSession(in: directory)
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
        let (session, _) = makeSession(in: directory)
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
