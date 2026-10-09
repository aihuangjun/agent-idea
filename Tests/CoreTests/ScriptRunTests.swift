import Core
import Foundation
import Testing

// MARK: - 脚本 → 命令

@Test func pep723ScriptBlockIsRecognizedOnlyWhenWellFormed() {
    let pep723 = "# /// script\n# requires-python = \">=3.10\"\n# dependencies = [\"requests\"]\n#\n# ///\nimport requests\n"
    #expect(ScriptRunner.hasInlineScriptMetadata(pep723))
    #expect(ScriptRunner.hasInlineScriptMetadata(pep723.replacingOccurrences(of: "\n", with: "\r\n")))
    #expect(ScriptRunner.hasInlineScriptMetadata("#!/usr/bin/env -S uv run\n" + pep723), "shebang 在前面也算")
    #expect(ScriptRunner.hasInlineScriptMetadata("# /// script\n# ///\n"), "空块也是声明")
    #expect(!ScriptRunner.hasInlineScriptMetadata("import os\nprint(1)\n"))
    #expect(!ScriptRunner.hasInlineScriptMetadata("# /// script\n# dependencies = []\n"), "没闭合")
    #expect(!ScriptRunner.hasInlineScriptMetadata("# /// script\nimport os\n# ///\n"), "中间夹了代码")
    #expect(!ScriptRunner.hasInlineScriptMetadata("# /// pyproject\n# ///\n"), "别的类型不算")
    #expect(!ScriptRunner.hasInlineScriptMetadata("    # /// script\n    # ///\n"), "要顶格")
    #expect(!ScriptRunner.hasInlineScriptMetadata("#/// script\n#///\n"))
}

@Test func pythonScriptsPickUvOrPython3FromTheLoginPath() {
    let script = URL(fileURLWithPath: "/proj/tools/my job.py")
    let pep723 = "# /// script\n# dependencies = []\n# ///\nprint(1)\n"
    let environment = ["PATH": "/custom/bin:/usr/bin:/bin", "HOME": "/Users/me"]
    // uv 只装在 ~/.local/bin（PATH 里没有它，常见：那一行只写在 .zshrc 里）
    let present: Set<String> = ["/Users/me/.local/bin/uv", "/usr/bin/python3", "/opt/homebrew/bin/python3"]
    let exists: (String) -> Bool = { present.contains($0) }

    let uv = ScriptRunner.resolve(script: script, source: pep723, isExecutable: false, environment: environment, isExecutableFile: exists)
    #expect(uv.command?.executable.path == "/Users/me/.local/bin/uv")
    #expect(uv.command?.arguments == ["run", "--script", "/proj/tools/my job.py"])
    #expect(uv.command?.workingDirectory.path == "/proj/tools")
    #expect(uv.command?.display == "uv run --script my job.py")

    // 没声明：python3；/usr/bin 的系统占位版本排在最后，Homebrew 的先用上
    let plain = ScriptRunner.resolve(script: script, source: "print(1)", isExecutable: false, environment: environment, isExecutableFile: exists)
    guard case .ready(let python) = plain else { Issue.record("应当能跑：\(plain)"); return }
    #expect(python.executable.path == "/opt/homebrew/bin/python3")
    #expect(python.arguments == ["/proj/tools/my job.py"])
    #expect(python.display == "python3 my job.py")
    // 只有系统那个时也用它
    let onlySystem = ScriptRunner.resolve(script: script, source: "", isExecutable: false, environment: environment,
                                          isExecutableFile: { $0 == "/usr/bin/python3" })
    #expect((onlySystem.command?.executable.path) == "/usr/bin/python3")
    // PATH 里排前面的赢
    let custom = ScriptRunner.resolve(script: script, source: pep723, isExecutable: false, environment: environment,
                                      isExecutableFile: { $0 == "/custom/bin/uv" || $0 == "/Users/me/.local/bin/uv" })
    #expect((custom.command?.executable.path) == "/custom/bin/uv")

    // 找不到：说清楚缺什么，不起进程
    let missing = ScriptRunner.resolve(script: script, source: pep723, isExecutable: false, environment: environment, isExecutableFile: { _ in false })
    guard case .missing(let tool, let message) = missing else { Issue.record("应当缺 uv：\(missing)"); return }
    #expect(tool == "uv")
    #expect(message.contains("# /// script") && message.contains("my job.py"))
    if case .missing(let tool, _) = ScriptRunner.resolve(script: script, source: "", isExecutable: false, environment: environment, isExecutableFile: { _ in false }) {
        #expect(tool == "python3")
    } else {
        Issue.record("应当缺 python3")
    }
}

@Test func shellScriptsRunDirectlyWhenExecutableElseThroughTheirShell() {
    let environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"]
    let exists: (String) -> Bool = { ["/bin/bash", "/bin/zsh"].contains($0) }
    let deploy = URL(fileURLWithPath: "/proj/deploy.sh")
    let direct = ScriptRunner.resolve(script: deploy, source: "", isExecutable: true, environment: environment, isExecutableFile: exists).command
    #expect(direct?.executable == deploy && direct?.arguments == [] && direct?.display == "./deploy.sh")
    #expect(direct?.workingDirectory.path == "/proj")
    #expect((ScriptRunner.resolve(script: deploy, source: "", isExecutable: false, environment: environment, isExecutableFile: exists).command?.display) == "bash deploy.sh")
    let zsh = URL(fileURLWithPath: "/proj/x.zsh")
    #expect((ScriptRunner.resolve(script: zsh, source: "", isExecutable: false, environment: environment, isExecutableFile: exists).command?.executable.path) == "/bin/zsh")
    if case .missing(let tool, _) = ScriptRunner.resolve(script: URL(fileURLWithPath: "/proj/a.fish"), source: "", isExecutable: false,
                                                         environment: environment, isExecutableFile: exists) {
        #expect(tool == "fish")
    } else {
        Issue.record("没装 fish 应当报缺")
    }

    #expect(ScriptRunner.kind(forFileNamed: "a.py") == .python)
    #expect(ScriptRunner.kind(forFileNamed: "a.sh") == .shell)
    #expect(ScriptRunner.kind(forFileNamed: "a.swift") == nil)

    let env = ScriptRunner.environment(base: ["PATH": "/bin"])
    #expect(env["PYTHONUNBUFFERED"] == "1", "不设的话 print 要等进程退出才一起出来")
    #expect(env["PYTHONIOENCODING"] == "utf-8")
    #expect(env["PATH"] == "/bin")
}

private extension ScriptRunner.Resolution {
    var command: ScriptCommand? {
        if case .ready(let command) = self { return command }
        return nil
    }
}

// MARK: - 输出缓冲

@Test func consoleBufferStripsEscapesAndAppendsOnly() {
    var buffer = ConsoleBuffer()
    buffer.append("$ python3 a.py\n", kind: .system)
    buffer.append("\u{1B}[1;32mok\u{1B}[0m\r\n", kind: .output)
    buffer.append("\u{1B}]0;title\u{07}warn\n", kind: .error)
    buffer.append("50%\r100%\n", kind: .output)
    buffer.append("", kind: .output)
    #expect(buffer.text == "$ python3 a.py\nok\nwarn\n50%\n100%\n")
    #expect(buffer.segments.map(\.kind) == [.system, .output, .error, .output], "空串不成段")
    #expect(buffer.lineCount == 5)
    let generation = buffer.generation
    buffer.append("more\n", kind: .output)
    #expect(buffer.generation == generation, "追加不重画")
    buffer.clear()
    #expect(buffer.isEmpty && buffer.generation == generation + 1)
}

@Test func consoleBufferDropsTheOldestLinesPastTheLimit() {
    var buffer = ConsoleBuffer(lineLimit: 100)
    for index in 0..<100 { buffer.append("line \(index)\n", kind: .output) }
    #expect(buffer.droppedLines == 0)
    let generation = buffer.generation
    buffer.append("line 100\n", kind: .output)
    // 超了丢到 4/5：留 80 行
    #expect(buffer.lineCount == 80)
    #expect(buffer.droppedLines == 21)
    #expect(buffer.generation == generation + 1, "掐了开头要整个重画")
    #expect(buffer.text.hasPrefix("…前面 21 行已省略…\nline 21\n"))
    #expect(buffer.text.hasSuffix("line 100\n"))

    // 一大段里只丢开头几行
    var big = ConsoleBuffer(lineLimit: 10)
    big.append((0..<12).map { "l\($0)\n" }.joined(), kind: .output)
    #expect(big.lineCount == 8)
    #expect(big.text == "…前面 4 行已省略…\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\n")
    // 再丢一次：提示只有一行，数字累加
    big.append("a\nb\nc\n", kind: .error)
    #expect(big.text.hasPrefix("…前面 7 行已省略…\nl7\n"))
    #expect(big.segments.filter { $0.kind == .system }.count == 1)
}

@Test func utf8DecoderHoldsBackSplitCharacters() {
    let bytes = Array("你好 ok 🎉".utf8)
    var decoder = UTF8StreamDecoder()
    var text = ""
    // 一个字节一个字节地喂：每个多字节字符都会被切开
    for byte in bytes { text += decoder.decode(Data([byte])) }
    text += decoder.finish()
    #expect(text == "你好 ok 🎉")

    var tail = UTF8StreamDecoder()
    #expect(tail.decode(Data(bytes.prefix(4))) == "你", "第二个字只到了一个字节，先留着")
    #expect(tail.decode(Data(bytes[4..<bytes.count])) == "好 ok 🎉")
    var broken = UTF8StreamDecoder()
    #expect(broken.decode(Data([0xE4, 0xBD])) == "")
    #expect(broken.finish() == "\u{FFFD}", "流结束时半个字照样交出去，不吞")
}

// MARK: - 真起进程

@Test func scriptProcessStreamsBothPipesAndReportsExitLast() async throws {
    let command = ScriptCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                                arguments: ["-c", "pwd; echo out; echo err >&2; read line; echo \"stdin:[$line]\"; exit 3"],
                                workingDirectory: URL(fileURLWithPath: "/tmp"), display: "sh")
    let events = Recorder()
    _ = try ScriptProcess.start(command, environment: ["PATH": "/usr/bin:/bin"]) { events.add($0) }
    try await events.waitForExit()
    #expect(events.stdout.contains("/tmp") || events.stdout.contains("/private/tmp"), "在工作目录里跑")
    #expect(events.stdout.contains("out\n"))
    #expect(events.stdout.contains("stdin:[]"), "stdin 是 /dev/null：read 立刻 EOF，不会挂着")
    #expect(events.stderr == "err\n")
    #expect(events.exit?.status == 3 && events.exit?.signal == nil)
    #expect(events.exitWasLast)
}

@Test func stoppingAScriptKillsItsWholeProcessGroup() async throws {
    // shell 起一个子进程再等它：只停 shell 的话 sleep 会留下来（bash 不把 SIGTERM 转给子进程）
    let command = ScriptCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                                arguments: ["-c", "sleep 30 & echo child $!; wait"],
                                workingDirectory: URL(fileURLWithPath: "/tmp"), display: "sh")
    let events = Recorder()
    let process = try ScriptProcess.start(command, environment: ["PATH": "/usr/bin:/bin"]) { events.add($0) }
    let deadline = Date().addingTimeInterval(10)
    while !events.stdout.contains("\n"), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let child = try #require(Int32(events.stdout.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
    #expect(process.isRunning)
    process.stop()
    try await events.waitForExit()
    // sh 自己怎么死的不定：信号发给整组，sleep 先死的话 sh 的 wait 就返回了，可能抢在信号前正常退出
    #expect(events.exit != nil)
    #expect(!process.isRunning)
    // 子进程也没了（kill 0 只探测不发信号）
    let childDeadline = Date().addingTimeInterval(5)
    while kill(child, 0) == 0, Date() < childDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(kill(child, 0) != 0, "进程组里的 sleep 也该被停掉")
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private(set) var exit: (status: Int32, signal: Int32?)?
    private var afterExit = false

    func add(_ event: ScriptProcess.Event) {
        lock.lock()
        defer { lock.unlock() }
        if exit != nil { afterExit = true }
        switch event {
        case .output(let data): out.append(data)
        case .error(let data): err.append(data)
        case .exited(let status, let signal): exit = (status, signal)
        }
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    var exitWasLast: Bool { lock.lock(); defer { lock.unlock() }; return exit != nil && !afterExit }

    func waitForExit(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = exit != nil
            lock.unlock()
            if done { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("进程没在 \(timeout) 秒内结束")
    }
}

@Test func pythonScriptsInsideAProjectUseTheProjectEnvironment() {
    let environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"]
    let tools: Set<String> = ["/Users/me/.local/bin/uv", "/usr/bin/python3", "/work/plain/.venv/bin/python"]
    // laya 那种：pyproject.toml + uv.lock 在脚本的上一级，脚本没有 # /// script 声明
    let files: Set<String> = ["/work/laya/pyproject.toml", "/work/laya/uv.lock", "/work/plain/.venv/bin/python", "/work/half/pyproject.toml"]
    func resolve(_ path: String, _ source: String = "print(1)") -> ScriptRunner.Resolution {
        ScriptRunner.resolve(script: URL(fileURLWithPath: path), source: source, isExecutable: false, environment: environment,
                             isExecutableFile: { tools.contains($0) }, fileExists: { files.contains($0) })
    }

    let inProject = resolve("/work/laya/examples/01_noul.py").command
    #expect(inProject?.executable.path == "/Users/me/.local/bin/uv")
    #expect(inProject?.arguments == ["run", "/work/laya/examples/01_noul.py"])
    #expect(inProject?.workingDirectory.path == "/work/laya/examples", "uv 从工作目录往上自己找到项目")
    #expect(inProject?.display == "uv run 01_noul.py")
    // 声明块优先：项目里带 # /// script 的照样按声明跑（uv 本身也是这个规矩）
    #expect(resolve("/work/laya/x.py", "# /// script\n# ///\n").command?.arguments == ["run", "--script", "/work/laya/x.py"])
    // 只有 .venv（不是 uv 管的）：用它的解释器
    let venv = resolve("/work/plain/a.py").command
    #expect(venv?.executable.path == "/work/plain/.venv/bin/python")
    #expect(venv?.display == ".venv/bin/python a.py")
    // 只有 pyproject.toml、没有 uv.lock：不当 uv 项目，退回 python3
    #expect(resolve("/work/half/a.py").command?.executable.path == "/usr/bin/python3")
    #expect(resolve("/elsewhere/a.py").command?.display == "python3 a.py")

    // uv 项目但没装 uv：说清楚为什么要 uv
    let missing = ScriptRunner.resolve(script: URL(fileURLWithPath: "/work/laya/01_noul.py"), source: "", isExecutable: false,
                                       environment: environment, isExecutableFile: { $0 == "/usr/bin/python3" }, fileExists: { files.contains($0) })
    if case .missing(let tool, let message) = missing {
        #expect(tool == "uv" && message.contains("uv.lock"))
    } else {
        Issue.record("应当报缺 uv：\(missing)")
    }
}
