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
        ["fetch", "--prune", "--progress"],
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
    // git 2.56 起换了说法，还折了行（实际输出原样）
    #expect(GitSyncResult.mentionsAutostashConflict("Your local changes are stashed, however applying them\nresulted in conflicts.  You can either resolve the conflicts\nand then discard the stash with \"git stash drop\", or, if you\n"))
    #expect(!GitSyncResult.mentionsAutostashConflict("Created autostash: 60f75fd\nApplied autostash.\nSuccessfully rebased and updated refs/heads/main.\n"))
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

// MARK: - 分支

@Test func branchListParsesLocalRemoteAndDefault() {
    let text = [
        "refs/heads/feat/a\u{1f}\u{1f}*",
        "refs/heads/master\u{1f}origin/master\u{1f} ",
        "refs/heads/dev\u{1f}origin/dev\u{1f} ",
        "refs/remotes/origin/HEAD\u{1f}\u{1f} ",
        "refs/remotes/origin/dev\u{1f}\u{1f} ",
        "refs/remotes/origin/master\u{1f}\u{1f} ",
        "refs/remotes/up/stream/x\u{1f}\u{1f} ",
    ].joined(separator: "\n") + "\n"
    let list = GitBranchList.parse(text, remotes: ["origin", "up/stream"], remoteHead: "origin/master")
    #expect(list.local.map(\.name) == ["feat/a", "dev", "master"], "当前分支排最前，其余按名字")
    #expect(list.current == GitBranchList.Local(name: "feat/a", isCurrent: true))
    #expect(list.local(named: "master")?.upstream == "origin/master")
    #expect(list.remote == ["origin/master", "origin/dev", "up/stream/x"], "默认分支排最前，origin/HEAD 不算")
    #expect(list.defaultRemoteBranch == "origin/master")
    #expect(list.preferredRemote == "origin")
    #expect(list.localName(for: "up/stream/x") == "x", "远程名里有 / 也按最长前缀去")
    #expect(list.localName(for: "origin/feat/b") == "feat/b")
    #expect(list.suggestedUpstream(for: "feat/a") == "origin/master", "远程没有同名分支：跟踪默认分支")
    #expect(list.suggestedUpstream(for: "dev") == "origin/dev", "远程有同名分支：跟踪它")

    // 远程没告诉我们默认分支（没有 origin/HEAD）：退回 main / master
    let fallback = GitBranchList.parse("refs/remotes/origin/main\u{1f}\u{1f} \nrefs/remotes/origin/x\u{1f}\u{1f} \n", remotes: ["origin"], remoteHead: nil)
    #expect(fallback.defaultRemoteBranch == "origin/main")
    let none = GitBranchList.parse("refs/heads/main\u{1f}\u{1f}*\n", remotes: [], remoteHead: nil)
    #expect(none.defaultRemoteBranch == nil && none.preferredRemote == nil && none.suggestedUpstream(for: "main") == nil)
}

@Test func branchNameValidation() {
    #expect(GitBranchName.problem("", existing: []) == .empty)
    for bad in ["a b", "-x", "a..b", "a//b", "a/", "a.lock", "x~1", "x^", "a:b", "a?", "a*", "a[", "a\\b", ".hidden", "a/.b", "@", "a@{1}", "end."] {
        #expect(GitBranchName.problem(bad, existing: []) == .invalid, "\(bad)")
    }
    for good in ["feat/retrieval-four-lanes", "fix-1", "中文分支", "release/1.2"] {
        #expect(GitBranchName.problem(good, existing: []) == nil, "\(good)")
    }
    #expect(GitBranchName.problem("master", existing: ["master"]) == .exists)
}

/// 跟踪的上游与本地分支不同名（从 origin/master 开出来的 feature 分支）：推到远端的同名分支，不是光秃秃的 `git push`
/// （push.default=simple 下会被拒绝），更不能推进 master。
@Test func pushGoesToTheSameNameWhenUpstreamIsNamedDifferently() async throws {
    func runner(merge: String) -> FakeCommandRunner {
        FakeCommandRunner { arguments, _ in
            switch arguments {
            case ["rev-parse", "--abbrev-ref", "HEAD"]: return shellOutput("feat\n")
            case ["config", "--get", "branch.feat.merge"]: return shellOutput(merge + "\n")
            case ["config", "--get", "branch.feat.remote"]: return shellOutput("origin\n")
            default: return shellOutput("")
            }
        }
    }
    let differs = runner(merge: "refs/heads/master")
    _ = try await client(differs).push(repositoryRoot: URL(fileURLWithPath: "/repo"), hasUpstream: true)
    #expect(differs.calls(startingWith: "push") == [["push", "--porcelain", "--progress", "origin", "HEAD"]])
    let same = runner(merge: "refs/heads/feat")
    _ = try await client(same).push(repositoryRoot: URL(fileURLWithPath: "/repo"), hasUpstream: true)
    #expect(same.calls(startingWith: "push") == [["push", "--porcelain", "--progress"]])

    // fork 工作流：拉取跟踪 upstream/main、推送配成推到自己的 fork（pushRemote / remote.pushDefault）——git 自己会推到 fork 的同名分支，
    // 不能改成推进主仓库；用户明确设了 push.default 的也照他的来
    func configured(_ extra: [String: String]) -> FakeCommandRunner {
        FakeCommandRunner { arguments, _ in
            if arguments == ["rev-parse", "--abbrev-ref", "HEAD"] { return shellOutput("feat\n") }
            let values = ["branch.feat.merge": "refs/heads/main", "branch.feat.remote": "upstream"].merging(extra) { $1 }
            if arguments.count == 3, arguments[0] == "config", let value = values[arguments[2]] { return shellOutput(value + "\n") }
            return shellOutput("")
        }
    }
    for extra in [["branch.feat.pushRemote": "origin"], ["remote.pushDefault": "origin"], ["push.default": "upstream"], ["push.default": "current"]] {
        let fork = configured(extra)
        _ = try await client(fork).push(repositoryRoot: URL(fileURLWithPath: "/repo"), hasUpstream: true)
        #expect(fork.calls(startingWith: "push") == [["push", "--porcelain", "--progress"]], "\(extra)：照常 git push")
    }
    let simple = configured(["push.default": "simple", "remote.pushDefault": "upstream"])
    _ = try await client(simple).push(repositoryRoot: URL(fileURLWithPath: "/repo"), hasUpstream: true)
    #expect(simple.calls(startingWith: "push") == [["push", "--porcelain", "--progress", "upstream", "HEAD"]])

    // 建上游推到弹窗里说的那个远程，不写死 origin
    let noUpstream = FakeCommandRunner(responses: [])
    _ = try await client(noUpstream).push(repositoryRoot: URL(fileURLWithPath: "/repo"), hasUpstream: false, remote: "upstream")
    #expect(noUpstream.calls(startingWith: "push") == [["push", "--porcelain", "--progress", "-u", "upstream", "HEAD"]])
}

/// 真实 `git push --progress` 的 stderr（git 2.53）整段都是进度：推送成功的提示里不能冒出「Delta compression using up to 12 threads」。
@Test func realPushProgressIsFilteredCompletely() {
    let stderr = "Enumerating objects: 5, done.\nCounting objects:  20% (1/5)\rCounting objects: 100% (5/5), done.\nDelta compression using up to 12 threads\n"
        + "Compressing objects:  25% (1/4)\rCompressing objects: 100% (4/4), done.\nWriting objects:  20% (1/5)\rWriting objects: 100% (5/5), 4.41 KiB | 4.41 MiB/s, done.\n"
        + "Total 5 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)\n"
    #expect(GitProgress.removingProgress(stderr).isEmpty)
    #expect(GitProgress.removingProgress(stderr + "remote: error: pre-receive hook declined") == "remote: error: pre-receive hook declined")
}

/// 真 git：从 origin/main 开一个跟踪它的 feature 分支 → 同步能从 main 拉 → 推送推到远端的同名分支（main 不动）；
/// 签出远程分支建出跟踪它的本地分支；分支列表读得出来。
@Test func realGitBranchesCreateSyncPushAndCheckout() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let (mate, local) = try await makeRemoteAndClones(git, in: directory)
        try await git.createBranch("feat/x", from: "origin/main", track: true, repositoryRoot: local)
        var list = try await git.branches(repositoryRoot: local)
        #expect(list.current?.name == "feat/x" && list.current?.upstream == "origin/main")
        #expect(list.defaultRemoteBranch == "origin/main")

        // 同事往 main 推了一个；我们在 feature 分支上提交一个，同步把 main 的拉进来
        try "1\n2\n".write(to: mate.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await runGit(git, ["commit", "-q", "-am", "同事的改动"], in: mate, home: directory)
        try await runGit(git, ["push", "-q"], in: mate, home: directory)
        try "mine\n".write(to: local.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await runGit(git, ["add", "."], in: local, home: directory)
        try await runGit(git, ["commit", "-q", "-m", "我的改动"], in: local, home: directory)
        let synced = try await git.syncWithRemote(repositoryRoot: local)
        #expect(synced == GitSyncResult(upstream: "origin/main", pulled: 1, replayed: 1))

        // 推送：到远端的 feat/x，main 还是同事那个提交
        let mainBefore = try await runGit(git, ["rev-parse", "main"], in: directory.appendingPathComponent("remote.git"), home: directory)
        _ = try await git.push(repositoryRoot: local, hasUpstream: true)
        let remoteBranches = try await runGit(git, ["branch", "--format=%(refname:short)"], in: directory.appendingPathComponent("remote.git"), home: directory)
        #expect(remoteBranches.split(separator: "\n").map(String.init).sorted() == ["feat/x", "main"])
        #expect(try await runGit(git, ["rev-parse", "main"], in: directory.appendingPathComponent("remote.git"), home: directory) == mainBefore)

        // 同事开了个 dev 分支；我们 fetch 之后签出它：建出跟踪 origin/dev 的本地 dev
        try await runGit(git, ["push", "-q", "origin", "HEAD:refs/heads/dev"], in: mate, home: directory)
        try await git.fetch(repositoryRoot: local)
        try await git.createBranch("dev", from: "origin/dev", track: true, repositoryRoot: local)
        try await git.switchBranch(to: "main", repositoryRoot: local)
        try await git.setUpstream("origin/dev", repositoryRoot: local)
        list = try await git.branches(repositoryRoot: local)
        #expect(list.local.map(\.name) == ["main", "dev", "feat/x"])
        #expect(list.local(named: "dev")?.upstream == "origin/dev")
        #expect(list.current?.upstream == "origin/dev", "set-upstream-to 改的是当前分支")
        #expect(list.remote.first == "origin/main")
    }
}
