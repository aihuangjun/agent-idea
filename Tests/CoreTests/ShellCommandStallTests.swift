import Core
import Foundation
import Testing
import TestSupport

private let sh = URL(fileURLWithPath: "/bin/sh")

/// 一声不吭挂着的命令：看门狗到点就停掉它、抛 `ShellCommandStalled`，不会跟着它一起挂。
@Test func stalledCommandIsStoppedAndReported() async throws {
    let started = Date()
    do {
        _ = try await ShellCommand().run(executable: sh, arguments: ["-c", "sleep 20"], stallTimeout: 0.5)
        Issue.record("应抛 ShellCommandStalled")
    } catch let stalled as ShellCommandStalled {
        #expect(stalled.seconds == 0.5)
        #expect(stalled.command.hasPrefix("sh -c"))
    }
    #expect(Date().timeIntervalSince(started) < 10, "到点就该回来，不能等 sleep 20 跑完")
}

/// 卡死的命令起的子进程还拿着管子（git 起的 ssh 就是这样）：停掉父进程之后照样马上回来，不去等管子的 EOF。
@Test func stalledCommandWhoseChildHoldsThePipesStillReturns() async throws {
    let started = Date()
    await #expect(throws: ShellCommandStalled.self) {
        _ = try await ShellCommand().run(executable: sh, arguments: ["-c", "sleep 20 & wait"], stallTimeout: 0.5)
    }
    #expect(Date().timeIntervalSince(started) < 10)
}

/// 一直有输出的命令不算卡死：总时长远超看门的时限，只要每次间隔都短，就跑完、拿到全部输出。
@Test func commandThatKeepsTalkingIsNotStopped() async throws {
    let output = try await ShellCommand().run(
        executable: sh, arguments: ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i; sleep 0.3; done; echo done >&2"],
        stallTimeout: 1.5
    )
    #expect(output.status == 0)
    #expect(output.text.split(separator: "\n").count == 10)
    #expect(output.standardError == "done")
}

/// 进程已经退出、管子却被它丢在后台的子进程拿着：不等那个子进程，稍等一下就拿已经读到的输出交差。
@Test func exitedCommandWithAnOrphanHoldingThePipesReturnsItsOutput() async throws {
    let started = Date()
    let output = try await ShellCommand().run(executable: sh, arguments: ["-c", "echo hi; (sleep 15) & exit 3"], stallTimeout: 5)
    #expect(output.status == 3)
    #expect(output.text == "hi\n")
    #expect(Date().timeIntervalSince(started) < 10, "不该等后台的 sleep 15")
}

/// 外面取消了：照样马上回来，是 CancellationError。
@Test func cancellingAWatchedCommandReturnsPromptly() async throws {
    let task = Task {
        try await ShellCommand().run(executable: sh, arguments: ["-c", "sleep 20"], stallTimeout: 30)
    }
    let started = Date()
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(Date().timeIntervalSince(started) < 10)
}

// MARK: - git fetch 用上看门狗

/// fetch 带 `--progress`（不然拉得慢的大仓库一直安静，会被当成卡死），卡死报成同步的错误；
/// 出错时 stderr 里的进度行不给人看。
@Test func fetchReportsStallsAndStripsProgressFromErrors() async throws {
    struct Runner: CommandRunning {
        let failure: Error
        let seen = Locked<[(arguments: [String], stallTimeout: TimeInterval?)]>([])
        func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?) async throws -> ShellOutput {
            seen.value.append((arguments, nil))
            throw failure
        }
        func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?, stallTimeout: TimeInterval) async throws -> ShellOutput {
            seen.value.append((arguments, stallTimeout))
            throw failure
        }
    }
    let repo = URL(fileURLWithPath: "/repo")
    let stalled = Runner(failure: ShellCommandStalled(command: "git fetch --prune", seconds: 30))
    await #expect(throws: GitSyncError.fetchStalled(seconds: 30)) {
        try await GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: stalled).fetch(repositoryRoot: repo)
    }
    #expect(stalled.seen.value.map(\.arguments) == [["fetch", "--prune", "--progress"]])
    #expect(stalled.seen.value.first?.stallTimeout == GitClient.networkStallTimeout)
    #expect(GitSyncError.fetchStalled(seconds: 30).localizedDescription.contains("30 秒没有任何动静"))

    let noisy = Runner(failure: ShellCommandError(
        command: "git fetch", status: 128,
        message: "remote: Enumerating objects: 5, done.\rremote: Counting objects:  40% (2/5)\rremote: Counting objects: 100% (5/5), done.\nReceiving objects:  60% (3/5)\rfatal: the remote end hung up unexpectedly"
    ))
    do {
        try await GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: noisy).fetch(repositoryRoot: repo)
        Issue.record("应抛错")
    } catch let error as ShellCommandError {
        #expect(error.message == "fatal: the remote end hung up unexpectedly")
        #expect(error.status == 128)
    }
}

@Test func progressLinesAreRecognized() {
    for line in ["Enumerating objects: 5, done.", "remote: Counting objects: 100% (5/5), done.", "Receiving objects:  45% (450/1000), 1.2 MiB | 300 KiB/s",
                 "Resolving deltas: 100% (3/3), done.", "remote: Total 3 (delta 0), reused 0 (delta 0), pack-reused 0", "remote: Compressing objects: 100% (2/2), done."] {
        #expect(GitProgress.removingProgress(line).isEmpty, "\(line) 是进度")
    }
    for line in ["fatal: unable to access 'https://x/': Could not resolve host: x", "ssh: connect to host github.com port 22: Operation timed out",
                 "error: RPC failed; curl 56", "Permission denied (publickey)."] {
        #expect(GitProgress.removingProgress(line) == line, "\(line) 不是进度")
    }
}

@Test func treeSelectionRetainsOnlyExistingPaths() {
    let order = ["a", "b", "c", "d"]
    var selection = TreeSelection()
    selection.select("b")
    selection.toggle("d", order: order)
    selection.toggle("a", order: order)
    #expect(selection.anchor == "a")
    // 锚点没了：落到剩下的里按行序最靠前的
    selection.retain(["b", "c", "d"], order: order)
    #expect(selection.paths == ["b", "d"] && selection.anchor == "b")
    let unchanged = selection
    selection.retain(["a", "b", "c", "d"], order: order)
    #expect(selection == unchanged)
    selection.retain([], order: order)
    #expect(selection.isEmpty && selection.anchor == nil)
}
