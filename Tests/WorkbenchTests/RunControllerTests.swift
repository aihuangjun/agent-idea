import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

/// 假的启动器：记下起了什么命令，事件由测试手动喂。
@MainActor
private final class FakeLauncher: ScriptLaunching {
    final class Handle: RunningScript {
        var stopped = false
        func stop() { stopped = true }
    }

    var launched: [(command: ScriptCommand, environment: [String: String])] = []
    var handles: [Handle] = []
    var sinks: [@Sendable (ScriptProcess.Event) -> Void] = []

    nonisolated func launch(_ command: ScriptCommand, environment: [String: String],
                            onEvent: @escaping @Sendable (ScriptProcess.Event) -> Void) throws -> any RunningScript {
        MainActor.assumeIsolated {
            launched.append((command, environment))
            sinks.append(onEvent)
            let handle = Handle()
            handles.append(handle)
            return handle
        }
    }

    func send(_ event: ScriptProcess.Event, run index: Int = -1) {
        let sink = index < 0 ? sinks.last! : sinks[index]
        sink(event)
    }
}

private let fakeEnvironment = ["PATH": "/fake/bin", "HOME": "/Users/nobody"]

@Test @MainActor func runningAScriptStreamsOutputAndEndsWithTheExitLine() throws {
    try withTemporaryDirectory { directory in
        let script = directory.appendingPathComponent("hello.py")
        try "# /// script\n# dependencies = []\n# ///\nprint('hi')\n".write(to: script, atomically: true, encoding: .utf8)
        let launcher = FakeLauncher()
        // uv 只在假 PATH 外的 ~/.local/bin 里没有：解析靠 isExecutableFile，这里放一个真的可执行文件进假 PATH
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let uv = bin.appendingPathComponent("uv")
        try "#!/bin/sh\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let run = RunController(launcher: launcher, environment: { ["PATH": bin.path, "HOME": directory.path] })

        run.run(script)
        #expect(run.isRunning)
        #expect(run.commandDisplay == "uv run --script hello.py")
        #expect(launcher.launched.first?.command.executable.path == uv.path)
        #expect(launcher.launched.first?.environment["PYTHONUNBUFFERED"] == "1", "不缓冲：输出边跑边出来")
        #expect(run.buffer.text == "$ uv run --script hello.py\n")

        // 中文被切在两块之间也拼得回来
        let bytes = Array("你好\n".utf8)
        launcher.send(.output(Data(bytes.prefix(2))))
        launcher.send(.output(Data(bytes.dropFirst(2))))
        launcher.send(.error(Data("warn\n".utf8)))
        run.flush()
        #expect(run.buffer.text == "$ uv run --script hello.py\n你好\nwarn\n")
        #expect(run.buffer.segments.map(\.kind) == [.system, .output, .error])
        #expect(run.isRunning)

        launcher.send(.output(Data("no newline".utf8)))
        launcher.send(.exited(status: 2, signal: nil))
        run.flush()
        #expect(!run.isRunning)
        #expect(run.exitStatus == 2)
        #expect(run.buffer.text.hasSuffix("no newline\n\n[进程已结束，退出码 2]\n"), "没换行的最后一行先补个换行：\(run.buffer.text)")
    }
}

@Test @MainActor func rerunningStopsThePreviousRunAndIgnoresItsLateOutput() throws {
    try withTemporaryDirectory { directory in
        let script = directory.appendingPathComponent("loop.sh")
        try "while true; do echo x; sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        let launcher = FakeLauncher()
        let run = RunController(launcher: launcher, environment: { ["PATH": "/usr/bin:/bin", "HOME": directory.path] })

        run.run(script)
        #expect(launcher.launched.first?.command.display == "bash loop.sh")
        launcher.send(.output(Data("first\n".utf8)), run: 0)
        run.flush()

        run.rerun()
        #expect(launcher.handles[0].stopped, "再运行之前先停掉正在跑的")
        #expect(launcher.launched.count == 2)
        // 上一次晚到的输出与退出不能写进这一次
        launcher.send(.output(Data("stale\n".utf8)), run: 0)
        launcher.send(.exited(status: 143, signal: 15), run: 0)
        launcher.send(.output(Data("second\n".utf8)), run: 1)
        run.flush()
        #expect(run.buffer.text == "$ bash loop.sh\nsecond\n")
        #expect(run.isRunning)

        // 停止：发给进程，结尾注明是停掉的
        run.stop()
        #expect(launcher.handles[1].stopped)
        launcher.send(.exited(status: 143, signal: 15), run: 1)
        run.flush()
        #expect(!run.isRunning)
        #expect(run.buffer.text.hasSuffix("[进程已结束，已停止，退出码 143]\n"))

        run.clear()
        #expect(run.buffer.isEmpty)
        #expect(run.canRerun, "清空不忘记脚本")
    }
}

@Test @MainActor func missingToolIsExplainedWithoutStartingAnything() throws {
    try withTemporaryDirectory { directory in
        let script = directory.appendingPathComponent("needs_uv.py")
        try "# /// script\n# ///\n".write(to: script, atomically: true, encoding: .utf8)
        let launcher = FakeLauncher()
        // HOME 指到空目录、PATH 只有一个空目录：哪里都没有 uv（常见安装位置 /opt/homebrew/bin 等上这台机器可能真有，换个文件名不行，
        // 所以这条只在本机确实找不到 uv 时才断言「没起进程」）
        let run = RunController(launcher: launcher, environment: { ["PATH": directory.path, "HOME": directory.path] })
        run.run(script)
        if launcher.launched.isEmpty {
            #expect(!run.isRunning)
            #expect(run.buffer.text.contains("找不到 uv"))
            #expect(run.buffer.segments.allSatisfy { $0.kind == .system })
        }

        run.run(directory.appendingPathComponent("gone.py"))
        #expect(!run.isRunning)
        #expect(run.buffer.text.hasPrefix("读不了 gone.py"))
    }
}

@Test @MainActor func runScriptSavesFirstAndAsksForTheRunWindow() async throws {
    try await withTemporaryDirectory { directory in
        let script = directory.appendingPathComponent("job.sh")
        try "echo hi\n".write(to: script, atomically: true, encoding: .utf8)
        let launcher = FakeLauncher()
        let run = RunController(launcher: launcher, environment: { ["PATH": "/usr/bin:/bin", "HOME": directory.path] })
        let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
        let session = ProjectSession(root: directory, git: nil, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: defaults), defaults: defaults, run: run)
        var asked = 0
        session.onRequestRunWindow = { asked += 1 }
        // 非当前会话：saveAll 不去 WebView 要文字（见 AGENTS.md），草稿同步写盘
        session.openFile(script, pinned: true)
        let deadline = Date().addingTimeInterval(10)
        while session.activeTab == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        session.applyEdit(path: script.path, text: "echo edited\n")
        session.runScript(script)
        while launcher.launched.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(try String(contentsOf: script, encoding: .utf8) == "echo edited\n", "跑之前先把草稿写盘")
        #expect(launcher.launched.count == 1)
        #expect(asked == 1)
        #expect(session.runnableActiveFile == script)

        session.tearDown()
        #expect(launcher.handles[0].stopped, "关项目要停掉在跑的脚本")

        // workbench 记住运行窗口开没开、多高
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
        #expect(!workbench.isRunWindowShown)
        workbench.isRunWindowShown = true
        workbench.runWindowHeight = 333
        let restored = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"))
        #expect(restored.isRunWindowShown && restored.runWindowHeight == 333)
    }
}

/// 真起进程走一遍：解析 → 起进程 → 后台线程的事件 → 定时并进缓冲 → 结尾那行。只用 /bin/sh，不跑 uv。
@Test @MainActor func realScriptRunsEndToEndThroughTheController() async throws {
    try await withTemporaryDirectory { directory in
        let script = directory.appendingPathComponent("real.sh")
        try "echo \"在 $(basename \"$PWD\")\"\necho 出错了 >&2\nexit 4\n".write(to: script, atomically: true, encoding: .utf8)
        let run = RunController(environment: { ["PATH": "/usr/bin:/bin", "HOME": directory.path] })
        run.run(script)
        let deadline = Date().addingTimeInterval(10)
        while run.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(run.exitStatus == 4)
        let text = run.buffer.text
        #expect(text.hasPrefix("$ bash real.sh\n"))
        #expect(text.contains("在 \(directory.lastPathComponent)\n"), "在脚本所在目录里跑：\(text)")
        #expect(run.buffer.segments.contains { $0.kind == .error && $0.text.contains("出错了") })
        #expect(text.hasSuffix("[进程已结束，退出码 4]\n"))
    }
}
