import Core
import Foundation

/// 起脚本进程这一步（测试换成假的，不真起进程）。
protocol ScriptLaunching {
    /// `onEvent` 可以在任何线程上回调；`.exited` 最后来、只来一次。返回停止它的办法。
    func launch(_ command: ScriptCommand, environment: [String: String],
                onEvent: @escaping @Sendable (ScriptProcess.Event) -> Void) throws -> any RunningScript
}

protocol RunningScript: AnyObject {
    func stop()
}

extension ScriptProcess: RunningScript {}

struct SystemScriptLauncher: ScriptLaunching {
    func launch(_ command: ScriptCommand, environment: [String: String],
                onEvent: @escaping @Sendable (ScriptProcess.Event) -> Void) throws -> any RunningScript {
        try ScriptProcess.start(command, environment: environment, onEvent: onEvent)
    }
}

/// 一个项目的「运行」工具窗口（照 IDEA 的 Run）：跑的是哪个脚本、输出、在不在跑、退出码。
///
/// 同一时间只跑一个：再运行（别的或同一个脚本）先把正在跑的停掉，IDEA 单实例运行配置也是这么做的。
@MainActor
final class RunController: ObservableObject {
    @Published private(set) var buffer = ConsoleBuffer()
    /// 最近一次运行的脚本（重新运行用）。
    @Published private(set) var script: URL?
    /// 最近一次运行的命令（`uv run --script 01_noul.py`）。
    @Published private(set) var commandDisplay: String?
    @Published private(set) var isRunning = false
    /// 最近一次结束时的退出码；还在跑或没跑过是 nil。
    @Published private(set) var exitStatus: Int32?

    /// 输出攒多久往界面上推一次：一行一推的话，刷屏的脚本会把主线程占满。
    static let flushInterval: TimeInterval = 0.05

    private let launcher: ScriptLaunching
    private let environment: () -> [String: String]
    private var running: (any RunningScript)?
    /// 每次运行一个号：停掉的那次晚到的输出 / 退出不能写进新这次。
    private var runID = 0
    private let inbox = Inbox()
    private var flushScheduled = false
    private var stoppedByUser = false

    init(launcher: ScriptLaunching = SystemScriptLauncher(),
         environment: @escaping () -> [String: String] = { LoginShellEnvironment.current }) {
        self.launcher = launcher
        self.environment = environment
    }

    var title: String { script?.lastPathComponent ?? "运行" }
    var canRerun: Bool { script != nil }

    /// 运行一个脚本。读的是磁盘上的内容：调用方先 `saveAll`（编辑器里看到的才是跑的）。
    func run(_ script: URL) {
        stopCurrent()
        runID += 1
        self.script = script
        exitStatus = nil
        stoppedByUser = false
        buffer.clear()

        let source: String
        do {
            source = String(decoding: try Data(contentsOf: script), as: UTF8.self)
        } catch {
            commandDisplay = nil
            buffer.append("读不了 \(script.lastPathComponent)：\(error.userFacingDescription)\n", kind: .system)
            return
        }
        let base = environment()
        let resolution = ScriptRunner.resolve(script: script, source: source,
                                              isExecutable: FileManager.default.isExecutableFile(atPath: script.path),
                                              environment: base)
        switch resolution {
        case .missing(_, let message):
            commandDisplay = nil
            buffer.append(message + "\n", kind: .system)
        case .ready(let command):
            commandDisplay = command.display
            buffer.append("$ \(command.display)\n", kind: .system)
            start(command, environment: ScriptRunner.environment(base: base))
        }
    }

    func rerun() {
        guard let script else { return }
        run(script)
    }

    /// 停止按钮：停整个进程组，结尾那行注明是停掉的。
    func stop() {
        guard isRunning else { return }
        stoppedByUser = true
        running?.stop()
    }

    func clear() { buffer.clear() }

    /// 关项目：停掉、不等它收尾（脚本不像 rebase 有中间状态要收拾）。
    func tearDown() {
        stopCurrent()
    }

    private func stopCurrent() {
        guard isRunning else { return }
        running?.stop()
        running = nil
        isRunning = false
        runID += 1      // 它晚到的输出与退出不再理会
    }

    private func start(_ command: ScriptCommand, environment: [String: String]) {
        let id = runID
        let inbox = inbox
        inbox.reset(for: id)
        do {
            running = try launcher.launch(command, environment: environment) { [weak self] event in
                guard inbox.accept(event, for: id) else { return }
                DispatchQueue.main.async { self?.scheduleFlush() }
            }
            isRunning = true
            Log.info("run", "运行 \(command.display)（\(command.workingDirectory.path)）")
        } catch {
            buffer.append("起不来 \(command.executable.path)：\(error.userFacingDescription)\n", kind: .system)
            Log.warn("run", "起 \(command.display) 失败：\(error)")
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    /// 把攒下的输出并进缓冲；退出了就补结尾那行。测试也直接调它，不等定时器。
    func flush() {
        let drained = inbox.drain(for: runID)
        for piece in drained.pieces { buffer.append(piece.text, kind: piece.kind) }
        guard let exit = drained.exit else { return }
        running = nil
        isRunning = false
        exitStatus = exit.status
        if !buffer.text.hasSuffix("\n"), !buffer.isEmpty { buffer.append("\n", kind: .system) }
        let reason = stoppedByUser ? "已停止，" : ""
        buffer.append("\n[进程已结束，\(reason)退出码 \(exit.status)]\n", kind: .system)
        Log.info("run", "\(commandDisplay ?? title) 结束，退出码 \(exit.status)")
    }

    /// 后台线程交来的事件先放这里（解码也在这里做：多字节字符可能被切在两块之间，按流各留各的尾巴）。
    private final class Inbox: @unchecked Sendable {
        struct Piece {
            let text: String
            let kind: ConsoleBuffer.Kind
        }
        private let lock = NSLock()
        private var id = 0
        private var pieces: [Piece] = []
        private var exit: (status: Int32, signal: Int32?)?
        private var outDecoder = UTF8StreamDecoder()
        private var errDecoder = UTF8StreamDecoder()

        func reset(for id: Int) {
            lock.lock()
            self.id = id
            pieces = []
            exit = nil
            outDecoder = UTF8StreamDecoder()
            errDecoder = UTF8StreamDecoder()
            lock.unlock()
        }

        /// 不是这一次运行的事件扔掉。
        func accept(_ event: ScriptProcess.Event, for id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard id == self.id else { return false }
            switch event {
            case .output(let data): append(outDecoder.decode(data), .output)
            case .error(let data): append(errDecoder.decode(data), .error)
            case .exited(let status, let signal):
                append(outDecoder.finish(), .output)
                append(errDecoder.finish(), .error)
                exit = (status, signal)
            }
            return true
        }

        private func append(_ text: String, _ kind: ConsoleBuffer.Kind) {
            guard !text.isEmpty else { return }
            // 同一种连着来的并成一段：控制台视图按段追加，段少一点画得快
            if let last = pieces.last, last.kind == kind {
                pieces[pieces.count - 1] = Piece(text: last.text + text, kind: kind)
            } else {
                pieces.append(Piece(text: text, kind: kind))
            }
        }

        func drain(for id: Int) -> (pieces: [Piece], exit: (status: Int32, signal: Int32?)?) {
            lock.lock()
            defer { lock.unlock() }
            guard id == self.id else { return ([], nil) }
            let result = (pieces, exit)
            pieces = []
            exit = nil
            return result
        }
    }
}
