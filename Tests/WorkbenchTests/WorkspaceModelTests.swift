import Core
import Foundation
import Testing
import TestSupport
@testable import Workbench

/// 按参数匹配返回输出的假 git。
final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable ([String], URL?) -> ShellOutput
    private let handler: Handler
    private let lock = NSLock()
    private(set) var calls: [[String]] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?) async throws -> ShellOutput {
        record(arguments)
        return handler(arguments, currentDirectory)
    }

    private func record(_ arguments: [String]) {
        lock.lock()
        calls.append(arguments)
        lock.unlock()
    }

    func calls(startingWith command: String) -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.first == command }
    }
}

private func text(_ string: String, status: Int32 = 0) -> ShellOutput {
    ShellOutput(status: status, standardOutput: Data(string.utf8), standardError: "")
}

@MainActor
private func makeWorkbench(in directory: URL, git runner: ScriptedRunner?) -> WorkbenchModel {
    let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
    let git = runner.map { GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: $0) }
    return WorkbenchModel(git: git, fileManager: .default, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
}

@MainActor
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
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

        session.toggleExpanded(project.appendingPathComponent("src").path)
        #expect(session.rows.map(\.node.name) == ["src", "main.py", "README.md"])
        session.collapse(project.appendingPathComponent("src").path)
        #expect(session.rows.count == 2)

        // 键盘：向下选中、右键展开、回车打开
        session.moveSelection(by: 1)
        #expect(session.selectedPath == project.appendingPathComponent("src").path)
        session.activateSelection(expandOnly: true)
        #expect(session.rows.count == 3)
        session.moveSelection(by: 1)
        session.activateSelection()
        #expect(session.activeTab?.fileURL?.lastPathComponent == "main.py")
        #expect(session.activeTab?.isPreview == false)

        // 定位当前文件：先折叠，再定位，祖先要重新展开并选中
        session.collapseAll()
        #expect(session.rows.count == 2)
        session.revealActiveTab()
        #expect(session.rows.count == 3)
        #expect(session.selectedPath == project.appendingPathComponent("src/main.py").path)
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
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
        workbench.openProject(a)
        workbench.openProject(b)
        #expect(workbench.sessions.map(\.project.name) == ["a", "b"])
        #expect(workbench.active?.project.name == "b")
        // 再开同一个只是切过去
        workbench.openProject(a)
        #expect(workbench.sessions.count == 2 && workbench.active?.project.name == "a")
        workbench.selectNextProject(offset: 1)
        #expect(workbench.active?.project.name == "b")
        // 每个项目各自的标签
        workbench.activate(workbench.sessions[0].id)
        workbench.active?.openFile(a.appendingPathComponent("a.txt"), pinned: true)
        #expect(workbench.sessions[0].tabs.count == 1 && workbench.sessions[1].tabs.isEmpty)

        // 重启：同一份 defaults 恢复
        let restored = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
        restored.restoreOpenProjects()
        #expect(restored.sessions.map(\.project.name) == ["a", "b"])
        #expect(restored.active?.project.name == "a")

        workbench.closeProject(workbench.sessions[0].id)
        #expect(workbench.active?.project.name == "b")
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
        #expect(session.activeTab?.title == "c.txt")

        session.openFile(directory.appendingPathComponent("c.txt"), pinned: true)
        #expect(session.tabs[1].isPreview == false)
        session.openFile(directory.appendingPathComponent("a.txt"), pinned: false)
        #expect(session.tabs.map(\.title) == ["b.txt", "c.txt", "a.txt"])

        await waitUntil { session.contents.values.allSatisfy { $0 != .loading } && session.contents.count == 3 }
        if case .code(let content, let language, let encoding, let lines, _) = session.contents["file:" + session.project.root.appendingPathComponent("a.txt").path] {
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
        let runner = ScriptedRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return text(root + "\n")
            case "rev-parse": return text("abc")
            case "status": return text("# branch.oid abc\u{0}# branch.head main\u{0}1 .M N... 100644 100644 100644 a b a.swift\u{0}? new.md\u{0}! .build/\u{0}")
            case "diff": return text("--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-x\n+y\n")
            default: return text("")
            }
        }
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 2 }
        #expect(session.hasGit)
        #expect(session.gitSnapshot.branch.name == "main")
        #expect(session.changeGroups.tracked.map(\.path) == ["a.swift"])
        #expect(session.changeGroups.untracked.map(\.path) == ["new.md"])

        let node = FileNode(url: directory.appendingPathComponent("a.swift"), name: "a.swift", isDirectory: false)
        #expect(session.gitStatus(for: node) == .change(.modified))
        let build = FileNode(url: directory.appendingPathComponent(".build"), name: ".build", isDirectory: true)
        #expect(session.gitStatus(for: build) == .ignored)

        let change = session.changeGroups.tracked[0]
        session.openDiff(change)
        await waitUntil { session.activeContent != .loading && session.activeContent != nil }
        guard case .diff(let diff, let language) = session.activeContent else { Issue.record("应是 diff 内容"); return }
        #expect(diff.addedCount == 1 && diff.removedCount == 1)
        #expect(language.highlightID == "swift")
        #expect(session.change(for: directory.appendingPathComponent("a.swift"))?.kind == .modified)

        let before = runner.calls(startingWith: "diff").count
        workbench.ignoreWhitespace = true
        await waitUntil { runner.calls(startingWith: "diff").count > before }
        #expect(runner.calls(startingWith: "diff").last?.contains("-w") == true)
    }
}

@Test @MainActor func commitStagesOnlySelectedPathsThenPushes() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        let committed = Locked(false)
        let runner = ScriptedRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return text(root + "\n")
            case "rev-parse" where arguments.contains("--short"): return text("abc1234\n")
            case "status":
                return committed.value
                    ? text("# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +1 -0\u{0}? c.txt\u{0}")
                    : text("# branch.oid x\u{0}# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +0 -0\u{0}1 .M N... 100644 100644 100644 a b a.txt\u{0}? b.txt\u{0}? c.txt\u{0}")
            case "commit": committed.value = true; return text("")
            case "push": return ShellOutput(status: 0, standardOutput: Data(), standardError: "To github.com:x/y.git\n   abc..def  main -> main")
            default: return text("")
            }
        }
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 3 }

        // 空信息不能提交
        #expect(!session.canCommit)
        session.commitMessage = "  "
        #expect(!session.canCommit)
        session.commitMessage = "feat: x"
        #expect(session.canCommit)

        // 去掉 c.txt
        let c = try #require(session.gitSnapshot.changes.first { $0.path == "c.txt" })
        session.setIncluded(false, for: c)
        #expect(!session.isIncludedInCommit(c))
        #expect(session.includedChanges.map(\.path).sorted() == ["a.txt", "b.txt"])

        session.commit(push: true)
        await waitUntil { !session.isCommitting && !session.isPushing && session.commitStatus != nil && runner.calls(startingWith: "push").count == 1 }

        let add = try #require(runner.calls(startingWith: "add").first)
        #expect(add == ["add", "-A", "--", "a.txt", "b.txt"])
        let commit = try #require(runner.calls(startingWith: "commit").first)
        #expect(commit == ["commit", "--quiet", "--only", "-m", "feat: x", "--", "a.txt", "b.txt"])
        #expect(runner.calls(startingWith: "push").first == ["push", "--porcelain"])
        #expect(session.commitMessage.isEmpty)
        if case .success(let message) = session.commitStatus { #expect(message.contains("main -> main")) } else { Issue.record("应是成功状态：\(String(describing: session.commitStatus))") }
        await waitUntil { session.changeGroups.total == 1 }
        // 提交过的路径从「不勾选」集合里清掉了；剩下的 c.txt 仍然是不勾选
        #expect(session.excludedFromCommit == ["c.txt"])
    }
}

@Test @MainActor func commitFailureSurfacesStderr() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        let runner = ScriptedRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return text(root + "\n")
            case "status": return text("# branch.head main\u{0}? a.txt\u{0}")
            case "add": return text("")
            case "commit": return ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: unable to auto-detect email address")
            default: return text("")
            }
        }
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 1 }
        session.commitMessage = "x"
        session.commit(push: false)
        await waitUntil { session.commitStatus != nil }
        if case .failure(let message) = session.commitStatus { #expect(message.contains("auto-detect email")) } else { Issue.record("应是失败状态") }
        #expect(session.commitMessage == "x", "失败时保留用户写的信息")
        #expect(runner.calls(startingWith: "push").isEmpty)
    }
}

@Test @MainActor func diffTabClosesWhenChangeDisappears() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        let clean = Locked(false)
        let runner = ScriptedRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return text(root + "\n")
            case "status":
                return clean.value ? text("# branch.head main\u{0}") : text("# branch.head main\u{0}? new.md\u{0}")
            default: return text("")
            }
        }
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 1 }
        session.openDiff(session.changeGroups.untracked[0], pinned: true)
        #expect(session.tabs.count == 1)

        clean.value = true
        session.refreshGit()
        await waitUntil { session.changeGroups.total == 0 }
        #expect(session.tabs.isEmpty)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
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
    #expect(file.title == "a.md" && diff.title == "a.md")
    #expect(diff.isDiff && !file.isDiff)
    let content = TabContent.code(text: "", language: .json, encoding: "UTF-8", lineCount: 3, modified: nil)
    #expect(content.statusSummary == ["3 行", "UTF-8", "JSON"])
}

@Test @MainActor func updaterDescribesAuthFailures() {
    let message = Updater.describe(Updater.UpdateError.http(404, hadToken: false))
    #expect(message.contains("gh auth login"))
    #expect(Updater.describe(Updater.UpdateError.http(404, hadToken: true)).contains("还没有发布记录"))
    #expect(Updater.describe(Updater.UpdateError.checksumMismatch).contains("校验"))
    #expect(Updater.shellQuoted("/Applications/It's.app") == "'/Applications/It'\\''s.app'")
}

@Test @MainActor func doubleClickIsDetectedByIntervalOnSameRow() async throws {
    try await withTemporaryDirectory { directory in
        let workbench = makeWorkbench(in: directory, git: nil)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        #expect(!session.registerClick(on: "a"))
        #expect(session.registerClick(on: "a"), "紧接着的第二下是双击")
        #expect(!session.registerClick(on: "a"), "双击之后再点从头算")
        #expect(!session.registerClick(on: "b"))
        #expect(!session.registerClick(on: "c"), "换了一行不算双击")
    }
}

@Test @MainActor func rollbackRoutesByChangeKind() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.resolvingSymlinksInPath().path
        try "x".write(to: directory.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        let runner = ScriptedRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return text(root + "\n")
            case "status": return text("# branch.head main\u{0}1 .M N... 100644 100644 100644 a b m.txt\u{0}1 A. N... 000000 100644 100644 0 b a.txt\u{0}2 R. N... 100644 100644 100644 a a R100 new.txt\u{0}old.txt\u{0}? junk.txt\u{0}")
            default: return text("")
            }
        }
        let workbench = makeWorkbench(in: directory, git: runner)
        workbench.openProject(directory)
        let session = try #require(workbench.active)
        await waitUntil { session.changeGroups.total == 4 }
        let byPath = Dictionary(uniqueKeysWithValues: session.gitSnapshot.changes.map { ($0.path, $0) })

        session.rollback(byPath["m.txt"]!)
        await waitUntil { !runner.calls(startingWith: "restore").isEmpty }
        #expect(runner.calls(startingWith: "restore").last == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "m.txt"])

        session.rollback(byPath["new.txt"]!)
        await waitUntil { runner.calls(startingWith: "restore").count == 2 }
        #expect(runner.calls(startingWith: "restore").last == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "new.txt", "old.txt"])

        session.rollback(byPath["a.txt"]!)
        await waitUntil { !runner.calls(startingWith: "rm").isEmpty }
        #expect(runner.calls(startingWith: "rm").last == ["rm", "-f", "-q", "--", "a.txt"])

        // 未跟踪：不走 git，文件进废纸篓
        session.deleteUntracked(byPath["junk.txt"]!)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("junk.txt").path))
    }
}
