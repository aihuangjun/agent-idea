import Core
import Foundation
import Testing
import TestSupport

/// 记录被调用的参数并按顺序吐回预设输出。
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable { let arguments: [String]; let directory: String? }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var responses: [ShellOutput]

    init(responses: [ShellOutput]) { self.responses = responses }

    func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?) async throws -> ShellOutput {
        record(Call(arguments: arguments, directory: currentDirectory?.path))
    }

    private func record(_ call: Call) -> ShellOutput {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
        guard !responses.isEmpty else { return ShellOutput(status: 0, standardOutput: Data(), standardError: "") }
        return responses.removeFirst()
    }
}

private func output(_ text: String, status: Int32 = 0) -> ShellOutput {
    ShellOutput(status: status, standardOutput: Data(text.utf8), standardError: "")
}

@Test func repositoryRootTrimsOutputAndFailsGracefully() async {
    let runner = FakeRunner(responses: [output("/repo\n"), output("fatal: not a git repository", status: 128)])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    #expect(await git.repositoryRoot(containing: URL(fileURLWithPath: "/repo/sub"))?.path == "/repo")
    #expect(await git.repositoryRoot(containing: URL(fileURLWithPath: "/elsewhere")) == nil)
    #expect(runner.calls.first?.arguments == ["rev-parse", "--show-toplevel"])
    #expect(runner.calls.first?.directory == "/repo/sub")
}

@Test func diffArgumentsPerChangeKind() async throws {
    let repo = URL(fileURLWithPath: "/repo")
    let git = { (runner: FakeRunner) in GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner) }

    // 未跟踪：跟 /dev/null 比，退出码 1 也算成功
    let untracked = FakeRunner(responses: [output("diff", status: 1)])
    _ = try await git(untracked).diff(change: GitChange(path: "new.txt", kind: .untracked), repositoryRoot: repo)
    #expect(untracked.calls[0].arguments == ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", "--no-index", "--", "/dev/null", "/repo/new.txt"])

    // 已跟踪、有 HEAD：对比 HEAD，忽略空白加 -w
    let modified = FakeRunner(responses: [output("head"), output("diff")])
    _ = try await git(modified).diff(change: GitChange(path: "a.swift", kind: .modified), repositoryRoot: repo, ignoreWhitespace: true)
    #expect(modified.calls[0].arguments == ["rev-parse", "--verify", "-q", "HEAD"])
    #expect(modified.calls[1].arguments == ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", "-w", "HEAD", "--", "a.swift"])

    // 没有提交的仓库：对比空树；重命名带上原路径
    let unborn = FakeRunner(responses: [output("", status: 1), output("diff")])
    _ = try await git(unborn).diff(change: GitChange(path: "b.swift", originalPath: "a.swift", kind: .renamed), repositoryRoot: repo)
    #expect(unborn.calls[1].arguments.suffix(4) == [GitClient.emptyTree, "--", "b.swift", "a.swift"])
}

@Test func snapshotUsesPorcelainV2() async throws {
    let runner = FakeRunner(responses: [output("# branch.head dev\u{0}? x.txt\u{0}")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let snapshot = try await git.snapshot(repositoryRoot: URL(fileURLWithPath: "/repo"))
    #expect(snapshot.branch.name == "dev")
    #expect(snapshot.changes.map(\.path) == ["x.txt"])
    #expect(runner.calls[0].arguments == ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"])
}

@Test func runCheckedThrowsWithStderr() async {
    let runner = FakeRunner(responses: [ShellOutput(status: 128, standardOutput: Data(), standardError: "fatal: bad")])
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
    }
}

@Test func commitAndPushArguments() async throws {
    let repo = URL(fileURLWithPath: "/repo")
    let runner = FakeRunner(responses: [output(""), output(""), output("abc1234\n"), output("ok")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let result = try await git.commit(paths: ["b.txt", "a.txt", "a.txt"], message: "msg", repositoryRoot: repo)
    #expect(result == GitClient.CommitResult(shortHash: "abc1234", fileCount: 2))
    #expect(runner.calls[0].arguments == ["add", "-A", "--", "a.txt", "b.txt"])
    #expect(runner.calls[1].arguments == ["commit", "--quiet", "--only", "-m", "msg", "--", "a.txt", "b.txt"])
    _ = try await git.push(repositoryRoot: repo, hasUpstream: false)
    #expect(runner.calls[3].arguments == ["push", "--porcelain", "-u", "origin", "HEAD"])
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
    let runner = FakeRunner(responses: [output(""), output("")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    try await git.restoreToHead(paths: ["new.swift", "old.swift", "new.swift"], repositoryRoot: repo)
    #expect(runner.calls[0].arguments == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "new.swift", "old.swift"])
    try await git.removeAdded(path: "a.txt", repositoryRoot: repo)
    #expect(runner.calls[1].arguments == ["rm", "-f", "-q", "--", "a.txt"])
}
