import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor
private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private func makeSession(_ directory: URL, git: GitClient) -> ProjectSession {
    let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
    return ProjectSession(root: directory, git: git, renderer: ContentRenderer(), preferences: ReadingPreferences(defaults: defaults), defaults: defaults)
}

private func runGit(_ git: GitClient, _ args: [String], in directory: URL) async throws -> String {
    try await ShellCommand().runChecked(executable: git.executable, arguments: args, currentDirectory: directory,
                                        environment: ["GIT_CONFIG_NOSYSTEM": "1", "HOME": directory.path, "PATH": "/usr/bin:/bin"])
        .text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 一个已有一次提交的仓库，a.txt 改过还没提交。
private func makeRepository(_ git: GitClient, in directory: URL) async throws -> String {
    _ = try await runGit(git, ["init", "-q", "-b", "main"], in: directory)
    _ = try await runGit(git, ["config", "user.email", "t@example.com"], in: directory)
    _ = try await runGit(git, ["config", "user.name", "t"], in: directory)
    try "a\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    _ = try await runGit(git, ["add", "a.txt"], in: directory)
    _ = try await runGit(git, ["commit", "-q", "-m", "init"], in: directory)
    try "a\nb\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    return try await runGit(git, ["rev-parse", "HEAD"], in: directory)
}

/// 用户反馈：「git 提交了，我点击了撤销，似乎不能撤销。也不会返回到 diff 看板里」。
/// 提交进撤销栈；状态栏的「撤销」/ ⌘Z 是 `reset --soft`：改动回到变更列表、信息填回、切到「提交」工具窗口；重做再提交回去。
@Test @MainActor func committingCanBeUndoneAndRedone() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let initial = try await makeRepository(git, in: directory)
        let session = makeSession(directory, git: git)
        defer { session.tearDown() }
        var requested: [ToolWindow] = []
        session.onRequestToolWindow = { requested.append($0) }
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)

        commit.message = "改 a\n\n正文"
        commit.commit(push: false)
        await waitUntil { session.canUndo && session.gitSnapshot.changes.isEmpty }
        #expect(session.undoTitle == "撤销提交")
        let committed = session.gitSnapshot.branch.headOID
        #expect(committed != initial && commit.message.isEmpty && commit.completedCommits == 1)
        // 状态栏：「已提交 abc1234「改 a」」+ 撤销
        #expect(session.banner == "已提交 \(committed.prefix(7))「改 a」")
        let action = try #require(session.bannerAction)
        #expect(action.title == "撤销")

        action.perform()
        await waitUntil { session.gitSnapshot.branch.headOID == initial && session.gitSnapshot.changes.count == 1 }
        #expect(session.gitSnapshot.branch.headOID == initial)
        #expect(session.gitSnapshot.changes.map(\.path) == ["a.txt"], "改动回到变更列表")
        #expect(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8) == "a\nb\n")
        #expect(commit.message == "改 a\n\n正文", "信息填回输入框")
        #expect(requested.last == .commit)
        #expect(session.canRedo && session.redoTitle == "重做提交")
        #expect(session.banner == "已撤销提交")

        session.redo()
        await waitUntil { session.gitSnapshot.branch.headOID == committed && session.gitSnapshot.changes.isEmpty }
        #expect(session.gitSnapshot.branch.headOID == committed)
        #expect(commit.message.isEmpty, "填回去的那段又提交进去了")
        #expect(session.canUndo && !session.canRedo)

        // 撤销之后 HEAD 被别人挪了（Agent 又提交了一次）：不撤，报原因，这一步丢掉
        try "a\nb\nc\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runGit(git, ["commit", "-q", "-am", "agent"], in: directory)
        session.undo()
        await waitUntil { session.banner?.contains("HEAD 已经不是这次提交了") == true }
        #expect(session.banner?.hasPrefix("不能撤销提交") == true)
        #expect(!session.canUndo)
        #expect(try await runGit(git, ["log", "-1", "--format=%s"], in: directory) == "agent")
    }
}

/// 提交历史里 HEAD 的右键「撤销提交」：不是本会话提交的也能撤（退回第一个父提交），撤销栈里同一个提交的那步跟着清掉。
@Test @MainActor func undoCommitFromHistoryResetsToParent() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let initial = try await makeRepository(git, in: directory)
        _ = try await runGit(git, ["commit", "-q", "-am", "终端里提交的\n\n正文"], in: directory)
        let session = makeSession(directory, git: git)
        defer { session.tearDown() }
        await waitUntil { session.commit != nil && session.gitSnapshot.branch.headOID != "" && session.gitSnapshot.changes.isEmpty }
        let head = try #require(try await git.log(repositoryRoot: directory, limit: 2).first)
        let root = try #require(try await git.log(repositoryRoot: directory, limit: 2).last)
        #expect(session.canUndoCommitFromHistory(head))
        #expect(!session.canUndoCommitFromHistory(root), "不是 HEAD、而且是根提交")

        session.undoCommitFromHistory(head)
        await waitUntil { session.gitSnapshot.branch.headOID == initial && session.gitSnapshot.changes.count == 1 }
        #expect(session.gitSnapshot.changes.map(\.path) == ["a.txt"])
        #expect(session.commit?.message == "终端里提交的\n\n正文")
        #expect(session.banner?.contains("已撤销提交 \(head.shortHash)") == true)
        #expect(!session.canUndo, "直接执行，不进撤销栈")
    }
}

/// 「提交并推送」：推送成了就撤不了（不给撤销按钮；⌘Z 报「已推送」并丢掉这一步），远程跟踪分支没更新也认得出来。
@Test @MainActor func pushedCommitIsNotUndone() async throws {
    try await withTemporaryDirectory { directory in
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let root = directory.resolvingSymlinksInPath().path
        let head = Locked("h1h1h1h1h1")
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(root + "\n")
            case "rev-parse" where arguments.contains("--git-path"): return shellOutput("/nonexistent/" + (arguments.last ?? ""))
            case "rev-parse": return shellOutput(head.value + "\n")
            case "symbolic-ref": return shellOutput("main\n")
            case "status":
                let changes = head.value.hasPrefix("h1") ? "1 .M N... 100644 100644 100644 a b a.txt\u{0}" : ""
                return shellOutput("# branch.oid \(head.value)\u{0}# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +0 -0\u{0}" + changes)
            case "commit": head.value = "h2h2h2h2h2"; return shellOutput("")
            // 远程跟踪分支上查不出来（推到了不更新它的地方），只能靠「本会话推送成功过」认
            case "branch": return shellOutput("")
            default: return shellOutput("")
            }
        }
        let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner),
                                     renderer: ContentRenderer(), preferences: ReadingPreferences(defaults: defaults), defaults: defaults)
        defer { session.tearDown() }
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)
        commit.message = "推上去"
        commit.commit(push: true)
        await waitUntil { session.canUndo && runner.calls(startingWith: "push").count == 1 && !commit.isPushing }
        #expect(session.canUndo)
        #expect(session.bannerAction == nil, "提交并推送的不给撤销按钮")
        #expect(commit.pushedHeads.contains("h2h2h2h2h2"))

        session.undo()
        await waitUntil { session.banner?.contains("已推送到远程") == true }
        #expect(session.banner == "不能撤销提交：已推送到远程，撤销需要强制推送，未执行")
        #expect(!session.canUndo)
        #expect(runner.calls(startingWith: "reset").isEmpty)
    }
}
