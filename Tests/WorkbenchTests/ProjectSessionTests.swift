import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor
private func makeWorkbench(in directory: URL, git runner: FakeCommandRunner?, defaults: UserDefaults? = nil) -> WorkbenchModel {
    let defaults = defaults ?? UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
    let git = runner.map { GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: $0) }
    return WorkbenchModel(git: git, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
}

@MainActor
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// 一个「有仓库、按脚本回答」的 git，status 输出由闭包给。
private func gitRunner(root: String, status: @escaping @Sendable () -> String, extra: @escaping @Sendable ([String]) -> ShellOutput? = { _ in nil }) -> FakeCommandRunner {
    FakeCommandRunner { arguments, _ in
        if let handled = extra(arguments) { return handled }
        switch arguments.first {
        case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(root + "\n")
        case "rev-parse" where arguments.contains("--short"): return shellOutput("abc1234\n")
        case "rev-parse": return shellOutput("abc")
        case "status": return shellOutput(status())
        default: return shellOutput("")
        }
    }
}

@Test @MainActor func openProjectListsRootAndRecordsRecent() async throws {
    try await withTemporaryDirectory { directory in
        let created = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: created.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "print(1)".write(to: created.appendingPathComponent("src/main.py"), atomically: true, encoding: .utf8)
        try "# hi".write(to: created.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let workbench = makeWorkbench(in: directory, git: nil)
        workbench.openProject(created)
        let session = try #require(workbench.active)
        let project = session.project.root
        #expect(session.project.name == "proj")
        #expect(session.rows.map(\.node.name) == ["src", "README.md"])
        #expect(workbench.recentProjects.first?.path == project.path)
        #expect(session.hasGit == false)
        #expect(session.isActive)

        session.toggleExpanded(project.appendingPathComponent("src").path)
        #expect(session.rows.map(\.node.name) == ["src", "main.py", "README.md"])
        session.collapse(project.appendingPathComponent("src").path)
        #expect(session.rows.count == 2)

        // 键盘：向下选中、右键展开、回车打开
        session.moveSelection(by: 1)
        #expect(session.selectedPath == project.appendingPathComponent("src").path)
        session.perform(.expand)
        #expect(session.rows.count == 3)
        session.moveSelection(by: 1)
        session.perform(.toggle)
        #expect(session.activeTab?.fileURL?.lastPathComponent == "main.py")
        #expect(session.activeTab?.isPreview == false)
        // 左键：文件上按左键跳到父目录，再按一次折叠
        session.perform(.collapseOrAscend)
        #expect(session.selectedPath == project.appendingPathComponent("src").path)
        session.perform(.collapseOrAscend)
        #expect(session.rows.count == 2)

        // 定位当前文件：祖先重新展开、选中、并要求切到项目视图
        workbench.toolWindow = .commit
        session.revealActiveTab()
        #expect(session.rows.count == 3)
        #expect(session.selectedPath == project.appendingPathComponent("src/main.py").path)
        #expect(session.revealRequests == 1)
        #expect(workbench.toolWindow == .project)

        workbench.closeProject()
        #expect(workbench.active == nil && workbench.sessions.isEmpty)
    }
}

@Test @MainActor func multipleProjectsSwitchAndRestore() async throws {
    try await withTemporaryDirectory { directory in
        let a = directory.appendingPathComponent("a"), b = directory.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try "x".write(to: a.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
        let workbench = makeWorkbench(in: directory, git: nil, defaults: defaults)
        workbench.openProject(a)
        workbench.openProject(b)
        #expect(workbench.sessions.map(\.project.name) == ["a", "b"])
        #expect(workbench.active?.project.name == "b")
        #expect(workbench.sessions[0].isActive == false && workbench.sessions[1].isActive)
        workbench.openProject(a)
        #expect(workbench.sessions.count == 2 && workbench.active?.project.name == "a")
        workbench.selectNextProject(offset: 1)
        #expect(workbench.active?.project.name == "b")
        workbench.activate(workbench.sessions[0].id)
        workbench.active?.openFile(a.appendingPathComponent("a.txt"), pinned: true)
        #expect(workbench.sessions[0].tabs.count == 1 && workbench.sessions[1].tabs.isEmpty)

        let restored = makeWorkbench(in: directory, git: nil, defaults: defaults)
        restored.restoreOpenProjects()
        #expect(restored.sessions.map(\.project.name) == ["a", "b"])
        #expect(restored.active?.project.name == "a")

        workbench.closeProject(workbench.sessions[0].id)
        #expect(workbench.active?.project.name == "b" && workbench.active?.isActive == true)
    }
}

@Test @MainActor func previewTabIsReusedUntilPinned() async throws {
    try await withTemporaryDirectory { directory in
        for name in ["a.txt", "b.txt", "c.txt"] {
            try name.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let workbench = makeWorkbench(in: directory, git: nil)
        workbench.openProject(directory)
        let session = try #require(workbench.active)

        session.openFile(directory.appendingPathComponent("a.txt"), pinned: false)
        session.openFile(directory.appendingPathComponent("b.txt"), pinned: false)
        #expect(session.tabs.map(\.title) == ["b.txt"])
        #expect(session.tabs[0].isPreview)

        session.pin(session.tabs[0].id)
        session.openFile(directory.appendingPathComponent("c.txt"), pinned: false)
        #expect(session.tabs.map(\.title) == ["b.txt", "c.txt"])
        session.openFile(directory.appendingPathComponent("c.txt"), pinned: true)
        #expect(session.tabs[1].isPreview == false)
        session.openFile(directory.appendingPathComponent("a.txt"), pinned: false)
        #expect(session.tabs.map(\.title) == ["b.txt", "c.txt", "a.txt"])

        await waitUntil { session.contents.values.allSatisfy { $0 != .loading } && session.contents.count == 3 }
        if case .code(let content, let language, let encoding, let lines, _) = session.contents[EditorTab.id(forFile: session.project.root.appendingPathComponent("a.txt"))] {
            #expect(content == "a.txt" && language == .plainText && encoding == "UTF-8" && lines == 1)
        } else { Issue.record("a.txt 应加载为代码") }

        session.closeTab(session.activeTabID!)
        #expect(session.activeTab?.title == "c.txt")
        session.selectNextTab(offset: -1)
        #expect(session.activeTab?.title == "b.txt")
        session.closeOtherTabs(session.activeTabID!)
        #expect(session.tabs.count == 1)
        session.closeAllTabs()
        #expect(session.tabs.isEmpty && session.activeTabID == nil)
    }
}

@Test @MainActor func gitSnapshotDrivesChangesAndDiffTabs() async throws {
    try await withTemporaryDirectory { directory in
        try "x".write(to: directory.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let root = directory.resolvingSymlinksInPath().path
        let runner = gitRunner(
            root: root,
            status: { "# branch.oid abc\u{0}# branch.head main\u{0}1 .M N... 100644 100644 100644 a b a.swift\u{0}? new.md\u{0}! .build/\u{0}" },
            extra: { $0.first == "diff" ? shellOutput("--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-x\n+y\n") : nil }
        )
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 2 }
        #expect(session.hasGit)
        #expect(session.gitSnapshot.branch.name == "main")
        #expect(session.changeGroups.tracked.map(\.path) == ["a.swift"])
        #expect(session.changeGroups.untracked.map(\.path) == ["new.md"])
        #expect(session.isRefreshingGit == false)

        let node = FileNode(url: directory.appendingPathComponent("a.swift"), name: "a.swift", isDirectory: false)
        #expect(session.gitStatus(for: node) == .change(.modified))
        let build = FileNode(url: directory.appendingPathComponent(".build"), name: ".build", isDirectory: true)
        #expect(session.gitStatus(for: build) == .ignored)

        // 文件还在磁盘上：diff 是可编辑的（文档 + 基线），不是 git 的 diff 文本
        session.openDiff(session.changeGroups.tracked[0])
        await waitUntil { session.activeContent != .loading && session.activeContent != nil }
        let tab = try #require(session.activeTab)
        let documentID = try #require(session.documentID(for: tab))
        #expect(session.activeContent == .editableDiff(documentID: documentID))
        #expect(session.contents[documentID]?.text == "x")
        #expect(session.change(for: directory.appendingPathComponent("a.swift"))?.kind == .modified)
    }
}

@Test @MainActor func cancelledRefreshIsNotAnError() async throws {
    try await withTemporaryDirectory { directory in
        // 第一次 status 很慢，被第二次顶掉：不能变成「git 出错」
        let session = ProjectSession(
            root: directory,
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: SlowRunner()),
            renderer: ContentRenderer(),
            preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!)
        )
        await waitUntil { session.hasGit }
        session.refreshGit()
        session.refreshGit()
        // 转圈是延迟出现的，不能拿它当「刷新结束」的信号；等结果落地
        await waitUntil(5) { session.gitSnapshot.branch.name == "main" || session.gitError != nil }
        #expect(session.gitError == nil)
        #expect(session.gitSnapshot.branch.name == "main")
        #expect(session.isRefreshingGit == false)
    }
}

/// 第一次 status 慢，之后的立刻返回。
private final class SlowRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var statusCalls = 0

    func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?) async throws -> ShellOutput {
        if arguments.first == "rev-parse" { return shellOutput(currentDirectory!.path + "\n") }
        if isFirstStatusCall() {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return shellOutput("# branch.head main\u{0}")
    }

    private func isFirstStatusCall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        statusCalls += 1
        return statusCalls == 1
    }
}

@Test @MainActor func commitStagesOnlySelectedPathsThenPushes() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        // 磁盘上有的路径才走 add；这两个文件要真的在
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let committed = Locked(false)
        let runner = gitRunner(root: root, status: {
            committed.value
                ? "# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +1 -0\u{0}? c.txt\u{0}"
                : "# branch.oid x\u{0}# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +0 -0\u{0}1 .M N... 100644 100644 100644 a b a.txt\u{0}? b.txt\u{0}? c.txt\u{0}"
        }, extra: { arguments in
            switch arguments.first {
            case "commit": committed.value = true; return shellOutput("")
            case "push": return ShellOutput(status: 0, standardOutput: Data(), standardError: "To github.com:x/y.git\n   abc..def  main -> main")
            default: return nil
            }
        })
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 3 }
        let commit = try #require(session.commit)

        #expect(!commit.canCommit)
        commit.message = "  "
        #expect(!commit.canCommit)
        commit.message = "feat: x"
        #expect(commit.canCommit)

        let c = try #require(session.gitSnapshot.changes.first { $0.path == "c.txt" })
        commit.setIncluded(false, for: c)
        #expect(!commit.isIncluded(c))
        #expect(commit.includedChanges.map(\.path).sorted() == ["a.txt", "b.txt"])

        commit.commit(push: true)
        await waitUntil { !commit.isCommitting && !commit.isPushing && commit.status != nil && runner.calls(startingWith: "push").count == 1 }

        #expect(runner.calls(startingWith: "add").first == ["add", "-A", "--", "a.txt", "b.txt"])
        #expect(runner.calls(startingWith: "commit").first == ["commit", "--quiet", "--only", "-m", "feat: x", "--", "a.txt", "b.txt"])
        #expect(runner.calls(startingWith: "push").first == ["push", "--porcelain"])
        #expect(commit.message.isEmpty)
        if case .success(let message) = commit.status { #expect(message.contains("main -> main")) } else { Issue.record("应是成功状态：\(String(describing: commit.status))") }
        await waitUntil { session.changeGroups.total == 1 }
        #expect(commit.excludedPaths == ["c.txt"])
    }
}

@Test @MainActor func commitFailureSurfacesStderr() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        let runner = gitRunner(root: root, status: { "# branch.head main\u{0}? a.txt\u{0}" }, extra: { arguments in
            arguments.first == "commit" ? ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: unable to auto-detect email address") : nil
        })
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 1 }
        let commit = try #require(session.commit)
        commit.message = "x"
        commit.commit(push: false)
        await waitUntil { commit.status != nil }
        if case .failure(let message) = commit.status { #expect(message.contains("auto-detect email")) } else { Issue.record("应是失败状态") }
        #expect(commit.message == "x", "失败时保留用户写的信息")
        #expect(runner.calls(startingWith: "push").isEmpty)
    }
}

@Test @MainActor func diffTabClosesWhenChangeDisappears() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        let clean = Locked(false)
        let runner = gitRunner(root: root, status: { clean.value ? "# branch.head main\u{0}" : "# branch.head main\u{0}? new.md\u{0}" })
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 1 }
        session.openDiff(try #require(session.changeGroups.untracked.first), pinned: true)
        #expect(session.tabs.count == 1)

        clean.value = true
        session.refreshGit()
        await waitUntil { session.changeGroups.total == 0 }
        #expect(session.tabs.isEmpty)
    }
}

@Test @MainActor func rollbackRoutesByChangeKind() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        try "x".write(to: directory.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        let runner = gitRunner(root: root, status: {
            "# branch.head main\u{0}1 .M N... 100644 100644 100644 a b m.txt\u{0}1 A. N... 000000 100644 100644 0 b a.txt\u{0}2 R. N... 100644 100644 100644 a a R100 new.txt\u{0}old.txt\u{0}? junk.txt\u{0}"
        })
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 4 }
        let commit = try #require(session.commit)
        let byPath = Dictionary(uniqueKeysWithValues: session.gitSnapshot.changes.map { ($0.path, $0) })

        // 开着 m.txt 的 diff 标签，回滚后应被关掉
        session.openDiff(try #require(byPath["m.txt"]), pinned: true)
        commit.rollback(try #require(byPath["m.txt"]))
        await waitUntil { !runner.calls(startingWith: "restore").isEmpty && session.tabs.isEmpty }
        #expect(runner.calls(startingWith: "restore").last == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "m.txt"])

        commit.rollback(try #require(byPath["new.txt"]))
        await waitUntil { runner.calls(startingWith: "restore").count == 2 }
        #expect(runner.calls(startingWith: "restore").last == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "new.txt", "old.txt"])

        commit.rollback(try #require(byPath["a.txt"]))
        await waitUntil { !runner.calls(startingWith: "rm").isEmpty }
        #expect(runner.calls(startingWith: "rm").last == ["rm", "-f", "-q", "--", "a.txt"])

        commit.delete(try #require(byPath["junk.txt"]))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("junk.txt").path))
    }
}

/// 变更列表里删已跟踪的文件：进废纸篓，开着的文件标签与 diff 标签都关掉；「已删除」的变更没有东西可删。
@Test @MainActor func deletingTrackedChangeTrashesFileAndClosesTabs() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        let file = directory.appendingPathComponent("m.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let runner = gitRunner(root: root, status: {
            "# branch.head main\u{0}1 .M N... 100644 100644 100644 a b m.txt\u{0}1 .D N... 100644 100644 000000 a a gone.txt\u{0}"
        })
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 2 }
        let commit = try #require(session.commit)
        let byPath = Dictionary(uniqueKeysWithValues: session.gitSnapshot.changes.map { ($0.path, $0) })
        #expect(!commit.canDelete(try #require(byPath["gone.txt"])))

        session.openFile(file, pinned: true)
        session.openDiff(try #require(byPath["m.txt"]), pinned: true)
        #expect(session.tabs.count == 2)
        commit.delete(try #require(byPath["m.txt"]))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(session.tabs.isEmpty)
        #expect(commit.status == nil)
    }
}

/// 目录树里删除：文件与目录都进废纸篓，目录下开着的标签一起关，选中挪到父节点，树立刻刷新。
@Test @MainActor func deletingTreeNodesTrashesAndUpdatesTree() async throws {
    try await withTemporaryDirectory { directory in
        let sub = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appendingPathComponent("inner.txt")
        try "i".write(to: inner, atomically: true, encoding: .utf8)
        let top = directory.appendingPathComponent("top.txt")
        try "t".write(to: top, atomically: true, encoding: .utf8)
        let workbench = makeWorkbench(in: directory, git: nil)
        workbench.openProject(directory)
        let session = try #require(workbench.active)

        session.openFile(top, pinned: true)
        let topNode = try #require(session.rows.first { $0.node.name == "top.txt" }?.node)
        session.select(topNode.id)
        session.delete(topNode)
        #expect(!FileManager.default.fileExists(atPath: top.path))
        #expect(session.tabs.isEmpty)
        #expect(session.selectedPath == nil)
        #expect(!session.rows.contains { $0.node.name == "top.txt" })

        session.expand(sub.path)
        session.openFile(inner, pinned: true)
        let innerNode = try #require(session.rows.first { $0.node.name == "inner.txt" }?.node)
        session.select(innerNode.id)
        let subNode = try #require(session.rows.first { $0.node.name == "sub" }?.node)
        session.delete(subNode)
        #expect(!FileManager.default.fileExists(atPath: sub.path))
        #expect(session.tabs.isEmpty)
        #expect(session.selectedPath == nil)
        #expect(!session.rows.contains { $0.node.name == "sub" || $0.node.name == "inner.txt" })

        // 项目根不能删
        session.delete(FileNode(url: directory, name: "root", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}

@Test func projectRelativePaths() {
    var project = Project(root: URL(fileURLWithPath: "/repo/sub"))
    project.repositoryRoot = URL(fileURLWithPath: "/repo")
    #expect(project.repositoryRelativePath(of: URL(fileURLWithPath: "/repo/sub/a/b.swift")) == "sub/a/b.swift")
    #expect(project.repositoryRelativePath(of: URL(fileURLWithPath: "/repo")) == "")
    #expect(project.repositoryRelativePath(of: URL(fileURLWithPath: "/other/x")) == nil)
    #expect(project.projectRelativeComponents(of: URL(fileURLWithPath: "/repo/sub/a/b.swift")) == ["a", "b.swift"])
    #expect(project.url(forRepositoryPath: "sub/a")?.path == "/repo/sub/a")
}

@Test func tabIdentityAndSummary() {
    let file = EditorTab(kind: .file(URL(fileURLWithPath: "/p/a.md")), isPreview: true)
    let diff = EditorTab(kind: .diff(GitChange(path: "a.md", kind: .modified)), isPreview: false)
    #expect(file.id != diff.id)
    #expect(file.id == EditorTab.id(forFile: URL(fileURLWithPath: "/p/a.md")))
    #expect(diff.id == EditorTab.id(forDiff: GitChange(path: "a.md", kind: .added)), "id 只看路径，不看种类")
    #expect(diff.isDiff && !file.isDiff)
    let content = TabContent.code(text: "", language: .json, encoding: "UTF-8", lineCount: 3, modified: nil)
    #expect(content.statusSummary == ["3 行", "UTF-8", "JSON"])
}

@Test func staleDetection() {
    let date = Date(timeIntervalSince1970: 100)
    let code = TabContent.code(text: "", language: .plainText, encoding: "UTF-8", lineCount: 0, modified: date)
    #expect(!FileContentLoader.isStale(code, modifiedOnDisk: date, exists: true))
    #expect(FileContentLoader.isStale(code, modifiedOnDisk: date.addingTimeInterval(1), exists: true))
    #expect(FileContentLoader.isStale(code, modifiedOnDisk: nil, exists: false))
    #expect(!FileContentLoader.isStale(.loading, modifiedOnDisk: nil, exists: true))
    #expect(FileContentLoader.isStale(.message(title: "文件不存在", detail: ""), modifiedOnDisk: date, exists: true))
    #expect(!FileContentLoader.isStale(.message(title: "文件不存在", detail: ""), modifiedOnDisk: nil, exists: false))
}

@Test func tabContentMapsToRenderPayload() {
    let url = URL(fileURLWithPath: "/p/docs/a.md")
    var tab = EditorTab(kind: .file(url), isPreview: false)
    tab.markdownView = .source
    tab.cursor = EditorCursor(line: 1, ch: 0)
    let markdown = TabContent.markdown(text: "# x", encoding: "UTF-8", lineCount: 1, modified: nil)
    #expect(markdown.renderContent(for: tab, diffMode: .unified)
        == .markdown(path: "/p/docs/a.md", markdown: "# x", documentDirectory: URL(fileURLWithPath: "/p/docs/"), view: .source, editable: false, cursor: EditorCursor(line: 1, ch: 0)))
    // 有草稿画草稿，可编辑时走编辑器
    #expect(markdown.renderContent(for: tab, diffMode: .unified, draft: "# y", editable: true)
        == .markdown(path: "/p/docs/a.md", markdown: "# y", documentDirectory: URL(fileURLWithPath: "/p/docs/"), view: .source, editable: true, cursor: EditorCursor(line: 1, ch: 0)))

    let change = GitChange(path: "new.txt", kind: .untracked)
    let diffTab = EditorTab(kind: .diff(change), isPreview: true)
    let empty = FileDiff(oldPath: nil, newPath: "new.txt", isBinary: false, hunks: [])
    #expect(TabContent.diff(empty, language: .plainText).renderContent(for: diffTab, diffMode: .sideBySide)
        == .diff(path: "new.txt", language: nil, diff: empty, mode: .sideBySide, emptyReason: "这是一个空文件。"))
    #expect(TabContent.binary(sizeBytes: 10).renderContent(for: tab, diffMode: .unified)
        == .message(title: "二进制文件", detail: "a.md · \(TabContent.byteCount(10))\n这个阅读器只显示文本。"))
}

@Test @MainActor func updaterDescribesAuthFailures() {
    let message = Updater.describe(Updater.UpdateError.http(404, hadToken: false))
    #expect(message.contains("gh auth login"))
    #expect(Updater.describe(Updater.UpdateError.http(404, hadToken: true)).contains("还没有发布过 Release"))
    #expect(Updater.describe(Updater.UpdateError.checksumMismatch).contains("校验"))
    #expect(Updater.shellQuoted("/Applications/It's.app") == "'/Applications/It'\\''s.app'")
}
