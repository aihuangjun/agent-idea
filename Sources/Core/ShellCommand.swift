import Foundation

public struct ShellCommandError: Error, Equatable, Sendable {
    public let command: String
    public let status: Int
    /// 子进程的 stderr，已去掉首尾空白。给用户看的提示要靠它，否则只剩一句「失败了」。
    public let message: String

    public init(command: String, status: Int, message: String) {
        self.command = command
        self.status = status
        self.message = message
    }
}

/// 一次命令跑完之后留下的东西。
public struct ShellOutput: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: String

    public init(status: Int32, standardOutput: Data, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// stdout 按 UTF-8 解码。用 `String(decoding:)`：遇到非法字节换成替换符而不是整段返回 nil，
    /// 否则一份混进半个多字节字符的 diff 会变成空结果。
    public var text: String { String(decoding: standardOutput, as: UTF8.self) }
}

/// 命令连续好几秒一个字节都没输出，被当成卡死停掉了（见 `CommandRunning.run(…stallTimeout:)`）。
public struct ShellCommandStalled: Error, Equatable, Sendable, LocalizedError {
    public let command: String
    public let seconds: TimeInterval

    public init(command: String, seconds: TimeInterval) {
        self.command = command
        self.seconds = seconds
    }

    public var errorDescription: String? { "\(command) 连续 \(Int(seconds)) 秒没有任何输出，已经停掉" }
}

/// 跑外部命令的抽象。模型层只依赖它，测试注入假实现，不真的起 git。
public protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ShellOutput

    /// 同上，但带看门狗：子进程连续 `stallTimeout` 秒一个字节都没往 stdout / stderr 写，就当它卡死了——
    /// 停掉它、抛 `ShellCommandStalled`。给走网络的命令用（`git fetch --progress`）：连不上、或连上了却不来数据的 ssh
    /// 可以一直挂着，等它的按钮就一直灰着。按「多久没动静」而不是「总共多久」判：大仓库慢慢拉、进度一直在走的不会被误杀。
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        stallTimeout: TimeInterval
    ) async throws -> ShellOutput
}

public extension CommandRunning {
    /// 替身默认不看门：直接跑。
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        stallTimeout: TimeInterval
    ) async throws -> ShellOutput {
        try await run(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment)
    }
}

/// 真的起一个进程。
public struct ShellCommand: CommandRunning {
    public init() {}

    /// SIGTERM 之后留给子进程自己收尾的时间。
    static let terminationGrace: TimeInterval = 3
    /// 进程已经退出、管子却还有人拿着（git 起的 ssh 还挂着）时，再等这么久就不等了，拿已经读到的输出交差。
    static let pipeGraceAfterExit: TimeInterval = 2

    public func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ShellOutput {
        try await launch(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment, capture: Capture())
    }

    public func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stallTimeout: TimeInterval
    ) async throws -> ShellOutput {
        let capture = Capture()
        let command = ([executable.lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
        let poll = UInt64(min(0.25, stallTimeout / 4) * 1_000_000_000)
        // 看门狗与命令赛跑，谁先有结果用谁的，并且不等输的那个收尾：卡死的命令被 SIGTERM 之后，它起的 ssh 可能还拿着管子，
        // 读管子的那一半要等 ssh 自己死了才回得来——等它就又卡住了，这正是看门狗要绕开的
        return try await Self.firstOf({
            try await launch(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment, capture: capture)
        }, {
            while true {
                try await Task.sleep(nanoseconds: poll)
                switch capture.check(stallTimeout: stallTimeout, pipeGrace: Self.pipeGraceAfterExit) {
                case .running: continue
                case .exitedWithPipesHeld(let output): return output
                case .stalled: throw ShellCommandStalled(command: command, seconds: stallTimeout)
                }
            }
        })
    }

    private func launch(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        capture: Capture
    ) async throws -> ShellOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // stdin 堵死：不设的话子进程继承我们的 stdin，git 一旦决定问点什么就会安静地等一个永远不会有的回答。
        process.standardInput = FileHandle.nullDevice
        // 退出码靠 terminationHandler 拿，**不用 waitUntilExit**：它内部转 run loop 等通知，在协作线程池上偶发
        // 收不到、子进程都没了还一直等（2026-09-02 发布时测试套件就这么挂过一次）。handler 要在 run() 之前装好。
        let exit = ExitWaiter()
        process.terminationHandler = {
            capture.exited($0.terminationStatus)
            exit.finish($0.terminationStatus)
        }

        try process.run()

        return try await withTaskCancellationHandler {
            // 两根管子必须同时读：只读一根的话另一根 64KB 缓冲写满后子进程就阻塞，表现是「一直在转」。
            async let outDone: Void = Self.drain(outPipe.fileHandleForReading) { capture.append($0, isError: false) }
            async let errDone: Void = Self.drain(errPipe.fileHandleForReading) { capture.append($0, isError: true) }
            _ = await (outDone, errDone)
            let status = await exit.status()
            // 被取消而死的进程退出码是 15（SIGTERM）。这不是「命令失败」，调用方要能用 CancellationError 区分：
            // 否则一次被新刷新顶掉的 git status 会被当成 git 出错显示在界面上。
            try Task.checkCancellation()
            return capture.output(status: status)
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM 可以被忽略，而我们接下来要等管子的 EOF——子进程不死，那个 EOF 就永远不来。
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(Self.terminationGrace * 1_000_000_000))
                guard process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// 把 `terminationHandler` 的一次回调变成一个可 await 的值。回调可能先于 await 到，也可能后到，两边都要接得住。
    private final class ExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Int32?
        private var continuation: CheckedContinuation<Int32, Never>?

        func finish(_ status: Int32) {
            lock.lock()
            result = status
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: status)
        }

        func status() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    /// 一块一块地读到 EOF，读到一块交一块（看门狗据此知道子进程还活着）。用 POSIX `read` 而不是 `FileHandle.read(upToCount:)`：
    /// 后者对管子要攒满指定字节数才返回，进度一行一行来的时候看起来就像没动静。
    ///
    /// 阻塞的读放在 GCD 的线程上，不占 Swift 并发的协作线程池：被看门狗停掉的命令，它的子进程（ssh）可能还一直拿着管子，
    /// 读它的线程就一直回不来；协作池总共才核数那么几个线程，重试几次占光了，整个应用的 async 都会停摆。
    private static func drain(_ handle: FileHandle, into sink: @escaping @Sendable (Data) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                read(handle, into: sink)
                continuation.resume()
            }
        }
    }

    private static func read(_ handle: FileHandle, into sink: (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                sink(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        try? handle.close()
    }

    /// 子进程的输出与退出码，边读边攒；看门狗要知道最后一次有输出是什么时候、进程退了没有。
    final class Capture: @unchecked Sendable {
        enum Check {
            case running
            /// 进程退了，管子还被它的子进程拿着：拿已经读到的交差。
            case exitedWithPipesHeld(ShellOutput)
            case stalled
        }

        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()
        private var lastActivity = Date()
        private var status: Int32?
        private var exitedAt: Date?

        func append(_ data: Data, isError: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isError { standardError.append(data) } else { standardOutput.append(data) }
            lastActivity = Date()
        }

        func exited(_ status: Int32) {
            lock.lock(); defer { lock.unlock() }
            self.status = status
            exitedAt = Date()
        }

        func output(status: Int32) -> ShellOutput {
            lock.lock(); defer { lock.unlock() }
            return ShellOutput(
                status: status,
                standardOutput: standardOutput,
                standardError: String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        func check(stallTimeout: TimeInterval, pipeGrace: TimeInterval, now: Date = Date()) -> Check {
            lock.lock()
            let status = status, exitedAt = exitedAt, lastActivity = lastActivity
            lock.unlock()
            if let status, let exitedAt {
                return now.timeIntervalSince(exitedAt) >= pipeGrace ? .exitedWithPipesHeld(output(status: status)) : .running
            }
            return now.timeIntervalSince(lastActivity) >= stallTimeout ? .stalled : .running
        }
    }

    /// 两件事谁先有结果就用谁的，另一件取消掉、**不等它收尾**。`withThrowingTaskGroup` 做不到这一点：
    /// 组要等所有子任务结束才返回，而输掉的那件可能卡在读管子上一直回不来。
    static func firstOf<T: Sendable>(
        _ first: @escaping @Sendable () async throws -> T,
        _ second: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.begin(continuation)
                for body in [first, second] {
                    race.add(Task {
                        do { race.finish(.success(try await body())) } catch { race.finish(.failure(error)) }
                    })
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var tasks: [Task<Void, Never>] = []
        private var result: Result<T, Error>?

        /// 外面已经被取消了的话 `finish` 会先于这里到，结果先存着。
        func begin(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func add(_ task: Task<Void, Never>) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                task.cancel()
                return
            }
            tasks.append(task)
            lock.unlock()
        }

        func finish(_ outcome: Result<T, Error>) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = outcome
            let waiting = continuation
            continuation = nil
            let running = tasks
            tasks = []
            lock.unlock()
            running.forEach { $0.cancel() }
            waiting?.resume(with: outcome)
        }
    }
}

public extension CommandRunning {
    /// 跑完要求退出码为 0，否则抛 `ShellCommandError`。
    func runChecked(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        acceptableStatuses: Set<Int32> = [0],
        stallTimeout: TimeInterval? = nil
    ) async throws -> ShellOutput {
        let output: ShellOutput
        if let stallTimeout {
            output = try await run(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment, stallTimeout: stallTimeout)
        } else {
            output = try await run(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment)
        }
        guard acceptableStatuses.contains(output.status) else {
            throw ShellCommandError(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                status: Int(output.status),
                message: output.standardError
            )
        }
        return output
    }
}

/// 在几个固定位置里找一个可执行文件。
///
/// GUI 应用不继承 shell 的 PATH（只有 `/usr/bin:/bin:/usr/sbin:/sbin`），
/// 在终端里跑得好好的命令，到了双击启动的应用里会变成「找不到」。所以显式列出候选路径。
public enum ExecutableLocator {
    public static func locate(_ candidates: [String]) -> URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
