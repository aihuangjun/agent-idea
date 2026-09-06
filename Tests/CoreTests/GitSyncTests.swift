import Core
import Foundation
import Testing
import TestSupport

@Test func revListCountParsing() {
    #expect(GitRevListCount.parse("2\t3\n").map { [$0.behind, $0.ahead] } == [2, 3])
    #expect(GitRevListCount.parse("0\t0") .map { [$0.behind, $0.ahead] } == [0, 0])
    #expect(GitRevListCount.parse("") == nil)
    #expect(GitRevListCount.parse("fatal: bad revision") == nil)
    #expect(GitRevListCount.parse("7") == nil)
}

@Test func syncSummaryReadsLikeItHappened() {
    #expect(GitSyncResult(upstream: "origin/main", pulled: 0, replayed: 0).summary == "已经是最新的（origin/main）")
    #expect(GitSyncResult(upstream: "origin/main", pulled: 0, replayed: 2).summary == "已经是最新的，本地领先 origin/main 2 个提交")
    #expect(GitSyncResult(upstream: "origin/main", pulled: 3, replayed: 0).summary == "已从 origin/main 拉取 3 个提交")
    #expect(GitSyncResult(upstream: "origin/main", pulled: 3, replayed: 1).summary == "已从 origin/main 拉取 3 个提交，本地 1 个提交重放在它们之上")
    // 上游没有新东西就不该动仓库
    #expect(GitSyncResult(upstream: "origin/main", pulled: 0, replayed: 5).didRebase == false)
    #expect(GitSyncResult(upstream: "origin/main", pulled: 1, replayed: 0).didRebase)
}

/// 假 git：按参数回答，记下调用顺序。
private func syncRunner(
    upstream: String? = "origin/main",
    counts: String = "2\t1",
    rebase: ShellOutput = shellOutput("")
) -> FakeCommandRunner {
    FakeCommandRunner { arguments, _ in
        switch arguments.first {
        case "rev-parse" where arguments.contains("@{upstream}"):
            return upstream.map { shellOutput($0 + "\n") } ?? shellOutput("", status: 128, stderr: "fatal: no upstream configured")
        case "rev-parse" where arguments.contains("--abbrev-ref"): return shellOutput("feature\n")
        case "rev-parse": return shellOutput("abc\n")  // hasHead
        case "rev-list": return shellOutput(counts)
        case "rebase" where arguments.contains("--abort"): return shellOutput("")
        case "rebase": return rebase
        default: return shellOutput("")
        }
    }
}

private func client(_ runner: FakeCommandRunner) -> GitClient {
    GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
}

@Test func syncFetchesThenRebasesOntoUpstream() async throws {
    let runner = syncRunner()
    let result = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
    #expect(result == GitSyncResult(upstream: "origin/main", pulled: 2, replayed: 1))
    #expect(runner.calls.map(\.arguments) == [
        ["rev-parse", "--verify", "-q", "HEAD"],
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
        ["fetch", "--prune"],
        ["rev-list", "--left-right", "--count", "origin/main...HEAD"],
        // --autostash：工作区有没提交的改动也能同步，不用先手动 stash
        ["rebase", "--autostash", "origin/main"],
    ])
}

@Test func syncSkipsRebaseWhenNothingNew() async throws {
    let runner = syncRunner(counts: "0\t4")
    let result = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
    #expect(result.pulled == 0)
    #expect(result.replayed == 4)
    #expect(runner.calls(startingWith: "rebase").isEmpty)
}

@Test func syncWithoutUpstreamFailsBeforeTouchingTheNetwork() async {
    let runner = syncRunner(upstream: nil)
    do {
        _ = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch {
        #expect(error as? GitSyncError == .noUpstream(branch: "feature"))
        #expect(error.userFacingDescription.contains("feature 没有跟踪远程分支"))
    }
    #expect(runner.calls(startingWith: "fetch").isEmpty)
}

@Test func syncOnUnbornRepositoryFails() async {
    let runner = FakeCommandRunner { _, _ in shellOutput("", status: 1) }
    do {
        _ = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch {
        #expect(error as? GitSyncError == .unborn)
    }
    #expect(runner.calls(startingWith: "fetch").isEmpty)
}

@Test func failedRebaseAbortsAndReportsWhyItRecovered() async {
    let runner = syncRunner(rebase: ShellOutput(status: 1, standardOutput: Data(), standardError: "CONFLICT (content): Merge conflict in a.swift"))
    do {
        _ = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch {
        #expect(error as? GitSyncError == .rebaseFailed(message: "CONFLICT (content): Merge conflict in a.swift", recovered: true))
        #expect(error.userFacingDescription.contains("已经回到同步前的状态"))
    }
    // 冲突了不能把仓库停在 rebase 中途：这个应用没有解冲突的界面
    #expect(runner.calls.map(\.arguments).last == ["rebase", "--abort"])
}

/// 真的跑一次系统 git：本地仓库落后远程一个提交、自己领先一个提交，同步之后本地提交重放在远程提交之上。
@Test func realGitSyncEndToEnd() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let shell = ShellCommand()
        let environment = ["GIT_CONFIG_NOSYSTEM": "1", "HOME": directory.path, "PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        @discardableResult
        func run(_ args: [String], in workingDirectory: URL) async throws -> String {
            try await shell.runChecked(executable: git.executable, arguments: args, currentDirectory: workingDirectory, environment: environment).text
        }

        // 远端（bare）+ 两个克隆：一个模拟同事，一个是我们
        let remote = directory.appendingPathComponent("remote.git")
        let mate = directory.appendingPathComponent("mate")
        let local = directory.appendingPathComponent("local")
        try await run(["init", "-q", "--bare", "-b", "main", remote.path], in: directory)
        try await run(["clone", "-q", remote.path, mate.path], in: directory)
        for (key, value) in [("user.email", "t@example.com"), ("user.name", "t")] {
            try await run(["config", key, value], in: mate)
        }
        try "1\n".write(to: mate.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await run(["add", "."], in: mate)
        try await run(["commit", "-q", "-m", "base"], in: mate)
        try await run(["push", "-q", "-u", "origin", "main"], in: mate)

        try await run(["clone", "-q", remote.path, local.path], in: directory)
        for (key, value) in [("user.email", "u@example.com"), ("user.name", "u")] {
            try await run(["config", key, value], in: local)
        }

        // 同事推了一个提交
        try "1\n2\n".write(to: mate.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await run(["commit", "-q", "-am", "同事的改动"], in: mate)
        try await run(["push", "-q"], in: mate)

        // 我们本地也提交了一个，还有一份没提交的改动（--autostash 要收起再放回来）
        try "mine\n".write(to: local.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await run(["add", "."], in: local)
        try await run(["commit", "-q", "-m", "我的改动"], in: local)
        try "草稿\n".write(to: local.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)

        let result = try await git.syncWithRemote(repositoryRoot: local)
        #expect(result == GitSyncResult(upstream: "origin/main", pulled: 1, replayed: 1))

        // 同事的改动到了本地，我们的提交排在它上面，没提交的改动还在
        #expect(try String(contentsOf: local.appendingPathComponent("shared.txt"), encoding: .utf8) == "1\n2\n")
        let subjects = try await run(["log", "--format=%s", "-n", "3"], in: local).split(separator: "\n").map(String.init)
        #expect(subjects == ["我的改动", "同事的改动", "base"])
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("draft.txt").path))

        // 再同步一次：已经是最新的，不该再 rebase
        let again = try await git.syncWithRemote(repositoryRoot: local)
        #expect(again == GitSyncResult(upstream: "origin/main", pulled: 0, replayed: 1))
    }
}
