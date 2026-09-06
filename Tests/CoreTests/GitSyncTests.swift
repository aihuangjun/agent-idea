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
    rebase: ShellOutput = shellOutput(""),
    rebaseState: String? = nil
) -> FakeCommandRunner {
    FakeCommandRunner { arguments, _ in
        switch arguments.first {
        case "rev-parse" where arguments.contains("@{upstream}"):
            return upstream.map { shellOutput($0 + "\n") } ?? shellOutput("", status: 128, stderr: "fatal: no upstream configured")
        case "rev-parse" where arguments.contains("--abbrev-ref"): return shellOutput("feature\n")
        case "rev-parse" where arguments.contains("--git-path"): return shellOutput(rebaseState ?? "/nonexistent/rebase-merge")
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
        // 用户自己在终端里开着的 rebase 不能被我们碰
        ["rev-parse", "--git-path", "rebase-merge"],
        ["rev-parse", "--git-path", "rebase-apply"],
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
    // 进来时没有 rebase 在跑，rebase 失败之后仓库停在了中途（rebase-merge 目录出现）：这时才该 abort
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-rebase-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: state) }
    let runner = FakeCommandRunner { arguments, _ in
        switch arguments.first {
        case "rev-parse" where arguments.contains("@{upstream}"): return shellOutput("origin/main\n")
        case "rev-parse" where arguments.contains("--git-path"): return shellOutput(state.path)
        case "rev-parse": return shellOutput("abc\n")
        case "rev-list": return shellOutput("2\t1")
        case "rebase" where arguments.contains("--abort"): return shellOutput("")
        case "rebase":
            try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            return ShellOutput(status: 1, standardOutput: Data(), standardError: "CONFLICT (content): Merge conflict in a.swift")
        default: return shellOutput("")
        }
    }
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

/// 用户自己在终端里开着一次 rebase：直接拒绝，绝不能 `--abort` 掉他解了一半的冲突。
@Test func syncRefusesWhileAnotherRebaseIsInProgress() async {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-rebase-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let runner = syncRunner(rebaseState: state.path)
    do {
        _ = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch {
        #expect(error as? GitSyncError == .rebaseInProgress)
    }
    #expect(runner.calls(startingWith: "rebase").isEmpty, "一条 rebase 命令都不许发")
    #expect(runner.calls(startingWith: "fetch").isEmpty)
}

/// rebase 还没建起中间状态就失败了（上游引用没了这类）：仓库没被动过，不用 abort，也别吓唬用户。
@Test func rebaseThatNeverStartedIsReportedAsRecovered() async {
    let runner = syncRunner(rebase: ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: invalid upstream 'origin/main'"))
    do {
        _ = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch {
        #expect(error as? GitSyncError == .rebaseFailed(message: "fatal: invalid upstream 'origin/main'", recovered: true))
    }
    #expect(!runner.calls.map(\.arguments).contains(["rebase", "--abort"]))
}

/// 看不懂 rev-list 的输出时报错，不能当成「已经是最新的」把 rebase 跳过去。
@Test func unreadableDivergenceIsAnError() async {
    let runner = syncRunner(counts: "fatal: bad revision\n")
    do {
        _ = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch {
        #expect(error as? GitSyncError == .unreadableDivergence("fatal: bad revision"))
    }
    #expect(runner.calls(startingWith: "rebase").isEmpty)
}

/// autostash 放不回去时 git 只当警告（退出码 0），结果里要带上这件事——不然界面会报「同步成功」，
/// 用户的改动却只剩在 stash 里。
@Test func autostashConflictIsCarriedInTheResult() async throws {
    let runner = syncRunner(rebase: shellOutput("Applying autostash resulted in conflicts.\nYour changes are safe in the stash.\nSuccessfully rebased and updated refs/heads/main.\n"))
    let result = try await client(runner).syncWithRemote(repositoryRoot: URL(fileURLWithPath: "/repo"))
    #expect(result.autostashConflicted)
    #expect(result.summary.contains("git stash list"))
    #expect(GitSyncResult(upstream: "origin/main", pulled: 1, replayed: 0).autostashConflicted == false)
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


// MARK: - 真 git

private let gitEnvironment = ["GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]

@discardableResult
private func runGit(_ git: GitClient, _ args: [String], in directory: URL, home: URL, acceptable: Set<Int32> = [0]) async throws -> String {
    var environment = gitEnvironment
    environment["HOME"] = home.path
    return try await ShellCommand().runChecked(executable: git.executable, arguments: args, currentDirectory: directory,
                                               environment: environment, acceptableStatuses: acceptable).text
}

/// 一个 bare 远端 + 「同事」的克隆 + 「我们」的克隆，远端已经有一个 base 提交。
private func makeRemoteAndClones(_ git: GitClient, in directory: URL) async throws -> (mate: URL, local: URL) {
    let remote = directory.appendingPathComponent("remote.git")
    let mate = directory.appendingPathComponent("mate")
    let local = directory.appendingPathComponent("local")
    try await runGit(git, ["init", "-q", "--bare", "-b", "main", remote.path], in: directory, home: directory)
    try await runGit(git, ["clone", "-q", remote.path, mate.path], in: directory, home: directory)
    for (key, value) in [("user.email", "t@example.com"), ("user.name", "t")] {
        try await runGit(git, ["config", key, value], in: mate, home: directory)
    }
    try "1\n".write(to: mate.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    try await runGit(git, ["add", "."], in: mate, home: directory)
    try await runGit(git, ["commit", "-q", "-m", "base"], in: mate, home: directory)
    try await runGit(git, ["push", "-q", "-u", "origin", "main"], in: mate, home: directory)

    try await runGit(git, ["clone", "-q", remote.path, local.path], in: directory, home: directory)
    for (key, value) in [("user.email", "u@example.com"), ("user.name", "u")] {
        try await runGit(git, ["config", key, value], in: local, home: directory)
    }
    return (mate, local)
}

/// 真 git：同事改了同一行、我们本地那一行也改了还没提交。rebase 本身成功，autostash 放不回去——
/// git 把这算警告、退出码是 0，所以必须自己认出来告诉用户改动进了 stash。
@Test func realGitAutostashConflictIsReported() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let (mate, local) = try await makeRemoteAndClones(git, in: directory)
        try "远端\n".write(to: mate.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await runGit(git, ["commit", "-q", "-am", "同事改了第一行"], in: mate, home: directory)
        try await runGit(git, ["push", "-q"], in: mate, home: directory)
        try "本地\n".write(to: local.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)

        let result = try await git.syncWithRemote(repositoryRoot: local)
        #expect(result.pulled == 1)
        #expect(result.autostashConflicted, "autostash 放不回去要报出来")
        #expect(result.summary.contains("git stash list"))
        // 改动确实在 stash 里，不是没了
        let stash = try await runGit(git, ["stash", "list"], in: local, home: directory)
        #expect(stash.contains("autostash") || !stash.isEmpty)
    }
}

/// 真 git：用户自己在终端里开着一次 rebase（停在冲突上）时拒绝同步，他的 rebase 状态原封不动。
@Test func realGitRefusesWhenARebaseIsAlreadyInProgress() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let (mate, local) = try await makeRemoteAndClones(git, in: directory)
        try "远端\n".write(to: mate.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await runGit(git, ["commit", "-q", "-am", "同事改了第一行"], in: mate, home: directory)
        try await runGit(git, ["push", "-q"], in: mate, home: directory)
        try "本地\n".write(to: local.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await runGit(git, ["commit", "-q", "-am", "我也改了第一行"], in: local, home: directory)
        try await runGit(git, ["fetch", "-q"], in: local, home: directory)
        // 用户在终端里自己 rebase，停在冲突上
        try await runGit(git, ["rebase", "origin/main"], in: local, home: directory, acceptable: [0, 1, 128])
        #expect(await git.isRebaseInProgress(repositoryRoot: local))

        do {
            _ = try await git.syncWithRemote(repositoryRoot: local)
            Issue.record("应拒绝")
        } catch {
            #expect(error as? GitSyncError == .rebaseInProgress)
        }
        // 他的 rebase 还在，冲突文件也还在
        #expect(await git.isRebaseInProgress(repositoryRoot: local))
        let status = try await runGit(git, ["status", "--porcelain"], in: local, home: directory)
        #expect(status.contains("shared.txt"))
        try await runGit(git, ["rebase", "--abort"], in: local, home: directory)
    }
}
