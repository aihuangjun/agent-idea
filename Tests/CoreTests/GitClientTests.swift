import Core
import Foundation
import Testing
import TestSupport

@Test func repositoryRootTrimsOutputAndFailsGracefully() async {
    let runner = FakeCommandRunner(responses: [shellOutput("/repo\n"), shellOutput("fatal: not a git repository", status: 128)])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    #expect(await git.repositoryRoot(containing: URL(fileURLWithPath: "/repo/sub"))?.path == "/repo")
    #expect(await git.repositoryRoot(containing: URL(fileURLWithPath: "/elsewhere")) == nil)
    #expect(runner.calls.first?.arguments == ["rev-parse", "--show-toplevel"])
    #expect(runner.calls.first?.directory == "/repo/sub")
}

@Test func diffArgumentsPerChangeKind() async throws {
    let repo = URL(fileURLWithPath: "/repo")
    let git = { (runner: FakeCommandRunner) in GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner) }

    // 未跟踪：跟 /dev/null 比，退出码 1 也算成功
    let untracked = FakeCommandRunner(responses: [shellOutput("diff", status: 1)])
    _ = try await git(untracked).diff(change: GitChange(path: "new.txt", kind: .untracked), repositoryRoot: repo)
    #expect(untracked.calls[0].arguments == ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", "--no-index", "--", "/dev/null", "/repo/new.txt"])

    // 已跟踪、有 HEAD：对比 HEAD，忽略空白加 -w
    let modified = FakeCommandRunner(responses: [shellOutput("head"), shellOutput("diff")])
    _ = try await git(modified).diff(change: GitChange(path: "a.swift", kind: .modified), repositoryRoot: repo, ignoreWhitespace: true)
    #expect(modified.calls[0].arguments == ["rev-parse", "--verify", "-q", "HEAD"])
    #expect(modified.calls[1].arguments == ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", "-w", "HEAD", "--", "a.swift"])

    // 没有提交的仓库：对比空树；重命名带上原路径
    let unborn = FakeCommandRunner(responses: [shellOutput("", status: 1), shellOutput("diff")])
    _ = try await git(unborn).diff(change: GitChange(path: "b.swift", originalPath: "a.swift", kind: .renamed), repositoryRoot: repo)
    #expect(unborn.calls[1].arguments.suffix(4) == [GitClient.emptyTree, "--", "b.swift", "a.swift"])
}

@Test func snapshotUsesPorcelainV2() async throws {
    let runner = FakeCommandRunner(responses: [shellOutput("# branch.head dev\u{0}? x.txt\u{0}")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let snapshot = try await git.snapshot(repositoryRoot: URL(fileURLWithPath: "/repo"))
    #expect(snapshot.branch.name == "dev")
    #expect(snapshot.changes.map(\.path) == ["x.txt"])
    #expect(runner.calls[0].arguments == ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"])
}

@Test func runCheckedThrowsWithStderr() async {
    let runner = FakeCommandRunner(responses: [ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: bad")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    do {
        _ = try await git.snapshot(repositoryRoot: URL(fileURLWithPath: "/repo"))
        Issue.record("应抛错")
    } catch let error as ShellCommandError {
        #expect(error.status == 128)
        #expect(error.message == "fatal: bad")
        #expect(error.command.hasPrefix("git status"))
    } catch {
        Issue.record("错误类型不对：\(error)")
    }
}

/// 真的跑一次系统 git：从建仓到 status 到 diff 走通。找不到 git 的机器上跳过。
@Test func realGitEndToEnd() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let shell = ShellCommand()
        func run(_ args: [String]) async throws {
            _ = try await shell.runChecked(executable: git.executable, arguments: args, currentDirectory: directory, environment: ["GIT_CONFIG_NOSYSTEM": "1", "HOME": directory.path, "PATH": "/usr/bin:/bin"])
        }
        try await run(["init", "-q", "-b", "main"])
        try await run(["config", "user.email", "t@example.com"])
        try await run(["config", "user.name", "t"])
        try "a\nb\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try ".build/\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "d".write(to: directory.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try await run(["add", "."])
        try await run(["commit", "-q", "-m", "init"])
        try "a\nc\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: directory.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "".write(to: directory.appendingPathComponent(".build/x.o"), atomically: true, encoding: .utf8)

        let root = await git.repositoryRoot(containing: directory)
        #expect(root?.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
        let snapshot = try await git.snapshot(repositoryRoot: directory)
        #expect(snapshot.branch.name == "main")
        let kinds = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0.kind) })
        #expect(kinds["f.txt"] == .modified)
        #expect(kinds["n.txt"] == .untracked)
        #expect(snapshot.ignored == [".build/"])

        let modified = UnifiedDiffParser.parse(try await git.diff(change: GitChange(path: "f.txt", kind: .modified), repositoryRoot: directory))
        #expect(modified.addedCount == 1 && modified.removedCount == 1)
        let untracked = UnifiedDiffParser.parse(try await git.diff(change: GitChange(path: "n.txt", kind: .untracked), repositoryRoot: directory))
        #expect(untracked.addedCount == 1 && untracked.oldPath == nil)

        // 回归：Agent 已经 git mv / git rm 过的东西也要能提交——原路径既不在磁盘也不在索引里，
        // 0.2.1 之前一股脑 `add -A` 会报 pathspec did not match
        try await run(["mv", "f.txt", "g.txt"])
        try await run(["rm", "-q", "d.txt"])
        let staged = try await git.snapshot(repositoryRoot: directory)
        let renamed = staged.changes.first { $0.kind == .renamed }
        #expect(renamed?.path == "g.txt" && renamed?.originalPath == "f.txt")
        #expect(staged.changes.first { $0.path == "d.txt" }?.kind == .deleted)
        let paths = staged.changes.map(\.path) + staged.changes.compactMap(\.originalPath)
        let result = try await git.commit(paths: paths, message: "move", repositoryRoot: directory)
        #expect(result.fileCount == 4)
        let after = try await git.snapshot(repositoryRoot: directory)
        #expect(after.changes.isEmpty)
        #expect(after.branch.headOID != snapshot.branch.headOID)

        // HEAD 里的内容当编辑器变更标记的基线；HEAD 里没有的文件是 nil
        #expect(await git.headContent(path: "g.txt", repositoryRoot: directory) == "a\nc\n")
        #expect(await git.headContent(path: "nope.txt", repositoryRoot: directory) == nil)

        // 回滚刚才那次提交里对 d.txt 的删除：文件回到工作区，成为一条未跟踪变更（只动工作区）
        let commits = try await git.log(repositoryRoot: directory, limit: 1)
        let latest = try #require(commits.first)
        let deleted = try #require(try await git.changedFiles(in: latest, repositoryRoot: directory).first { $0.path == "d.txt" })
        try await git.revert(change: deleted, in: latest, repositoryRoot: directory)
        #expect(try String(contentsOf: directory.appendingPathComponent("d.txt"), encoding: .utf8) == "d")
        let reverted = try await git.snapshot(repositoryRoot: directory)
        #expect(reverted.changes.map(\.path) == ["d.txt"])
    }
}

@Test func commitAndPushArguments() async throws {
    try await withTemporaryDirectory { repo in
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let runner = FakeCommandRunner(responses: [shellOutput(""), shellOutput(""), shellOutput("abc1234\n"), shellOutput("ok")])
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        let result = try await git.commit(paths: ["b.txt", "a.txt", "a.txt"], message: "msg", repositoryRoot: repo)
        #expect(result == GitClient.CommitResult(shortHash: "abc1234", fileCount: 2))
        #expect(runner.calls[0].arguments == ["add", "-A", "--", "a.txt", "b.txt"])
        #expect(runner.calls[1].arguments == ["commit", "--quiet", "--only", "-m", "msg", "--", "a.txt", "b.txt"])
        _ = try await git.push(repositoryRoot: repo, hasUpstream: false)
        #expect(runner.calls[3].arguments == ["push", "--porcelain", "-u", "origin", "HEAD"])
    }
}

/// 磁盘上已经没有的路径（删除、重命名的原路径）不能交给 `add`——已暂存时 pathspec 什么都匹配不到，git 直接报错。
@Test func commitStagesMissingPathsWithRmCached() async throws {
    try await withTemporaryDirectory { repo in
        try "new".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        // 目标失效的符号链接也算「在」：lstat 看得到它
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link"), withDestinationURL: repo.appendingPathComponent("nowhere"))
        let runner = FakeCommandRunner(responses: [shellOutput(""), shellOutput(""), shellOutput(""), shellOutput("abc1234\n")])
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        _ = try await git.commit(paths: ["new.txt", "old.txt", "gone.txt", "link"], message: "msg", repositoryRoot: repo)
        #expect(runner.calls[0].arguments == ["add", "-A", "--", "link", "new.txt"])
        #expect(runner.calls[1].arguments == ["rm", "--cached", "--ignore-unmatch", "--quiet", "--", "gone.txt", "old.txt"])
        #expect(runner.calls[2].arguments == ["commit", "--quiet", "--only", "-m", "msg", "--", "gone.txt", "link", "new.txt", "old.txt"])
    }
}

/// 只有磁盘上没有的路径时不跑 `add`（`add -A --` 后面没有 pathspec 会把整个仓库都加进去）。
@Test func commitSkipsAddWhenNothingPresent() async throws {
    try await withTemporaryDirectory { repo in
        let runner = FakeCommandRunner(responses: [shellOutput(""), shellOutput(""), shellOutput("abc1234\n")])
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        _ = try await git.commit(paths: ["gone.txt"], message: "msg", repositoryRoot: repo)
        #expect(runner.calls.map(\.arguments.first) == ["rm", "commit", "rev-parse"])
    }
}

@Test func gitEnvironmentNeverPromptsAndUsesLoginShell() {
    LoginShellEnvironment.override(["PATH": "/opt/homebrew/bin:/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent.sock"])
    defer { LoginShellEnvironment.override(nil) }
    let environment = GitClient.environment
    #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
    #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
}

@Test func loginShellEnvironmentParsesNulSeparatedEntries() {
    let data = Data("PATH=/a:/b\u{0}SSH_AUTH_SOCK=/tmp/x\u{0}garbage line\u{0}MULTI=a=b\u{0}".utf8)
    let parsed = LoginShellEnvironment.parse(data)
    #expect(parsed == ["PATH": "/a:/b", "SSH_AUTH_SOCK": "/tmp/x", "MULTI": "a=b"])
}

@Test func rollbackArguments() async throws {
    let repo = URL(fileURLWithPath: "/repo")
    let runner = FakeCommandRunner(responses: [shellOutput(""), shellOutput("")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    try await git.restoreToHead(paths: ["new.swift", "old.swift", "new.swift"], repositoryRoot: repo)
    #expect(runner.calls[0].arguments == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "new.swift", "old.swift"])
    try await git.removeAdded(path: "a.txt", repositoryRoot: repo)
    #expect(runner.calls[1].arguments == ["rm", "-f", "-q", "--", "a.txt"])
}

/// 回滚历史里的一个变更：拿那次提交的补丁反向 apply；补丁走临时文件，用完删掉。
@Test func revertAppliesReversePatchFromTemporaryFile() async throws {
    let repo = URL(fileURLWithPath: "/repo")
    let patchSeen = Locked<String?>(nil)
    let patchFile = Locked<String?>(nil)
    let runner = FakeCommandRunner { arguments, _ in
        if arguments.first == "diff" { return shellOutput("diff --git a/x b/x\n") }
        if arguments.first == "apply", let file = arguments.last {
            patchFile.value = file
            patchSeen.value = try? String(contentsOfFile: file, encoding: .utf8)
        }
        return shellOutput("")
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let commit = GitCommit(hash: "abc", shortHash: "abc", parents: ["p1"], authorName: "", authorEmail: "", date: Date(), subject: "", body: "")
    try await git.revert(change: GitChange(path: "x", originalPath: "old", kind: .renamed), in: commit, repositoryRoot: repo)
    #expect(runner.calls[0].arguments == ["diff", "--binary", "--no-color", "--no-ext-diff", "--find-renames", "p1", "abc", "--", "x", "old"])
    #expect(runner.calls[1].arguments.prefix(3) == ["apply", "--reverse", "--whitespace=nowarn"])
    #expect(patchSeen.value == "diff --git a/x b/x\n")
    #expect(patchFile.value.map { !FileManager.default.fileExists(atPath: $0) } == true, "临时补丁用完要删")

    // 没有补丁（这次提交没改这个文件）：报错而不是假装成功
    let empty = FakeCommandRunner(responses: [shellOutput("")])
    await #expect(throws: GitClient.GitRevertError.nothingToRevert) {
        try await GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: empty)
            .revert(change: GitChange(path: "x", kind: .modified), in: commit, repositoryRoot: repo)
    }
    #expect(empty.calls.count == 1)
    #expect(GitClient.GitRevertError.nothingToRevert.userFacingDescription.contains("没有可回滚"))
}

@Test func cancelledCommandThrowsCancellationError() async throws {
    // 真起一个会睡很久的进程，取消它：要抛 CancellationError 而不是「退出码 15」
    let task = Task {
        try await ShellCommand().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("应抛错")
    } catch is CancellationError {
    } catch {
        Issue.record("错误类型不对：\(error)")
    }
}

@Test func doubleClickDetectorUsesIntervalAndTarget() {
    var clock: TimeInterval = 0
    let detector = DoubleClickDetector(interval: 0.5, now: { clock })
    #expect(!detector.registerClick(on: "a"))
    clock = 0.3
    #expect(detector.registerClick(on: "a"), "间隔内的第二下是双击")
    clock = 0.4
    #expect(!detector.registerClick(on: "a"), "双击之后从头算")
    clock = 1.5
    #expect(!detector.registerClick(on: "a"), "超过间隔不算")
    clock = 1.6
    #expect(!detector.registerClick(on: "b"), "换了目标不算")
}
