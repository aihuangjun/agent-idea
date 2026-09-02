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

/// 跑外部命令的抽象。模型层只依赖它，测试注入假实现，不真的起 git。
public protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ShellOutput
}

/// 真的起一个进程。
public struct ShellCommand: CommandRunning {
    public init() {}

    /// SIGTERM 之后留给子进程自己收尾的时间。
    static let terminationGrace: TimeInterval = 3

    public func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
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

        try process.run()

        return try await withTaskCancellationHandler {
            // 两根管子必须同时读：只读一根的话另一根 64KB 缓冲写满后子进程就阻塞，表现是「一直在转」。
            async let outData = Self.readToEnd(outPipe.fileHandleForReading)
            async let errData = Self.readToEnd(errPipe.fileHandleForReading)
            let (out, err) = await (outData, errData)
            let status = await Task.detached(priority: .utility) { () -> Int32 in
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            // 被取消而死的进程退出码是 15（SIGTERM）。这不是「命令失败」，调用方要能用 CancellationError 区分：
            // 否则一次被新刷新顶掉的 git status 会被当成 git 出错显示在界面上。
            try Task.checkCancellation()
            return ShellOutput(
                status: status,
                standardOutput: out,
                standardError: String(decoding: err, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
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

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .utility) {
            let data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            return data
        }.value
    }
}

public extension CommandRunning {
    /// 跑完要求退出码为 0，否则抛 `ShellCommandError`。
    func runChecked(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        acceptableStatuses: Set<Int32> = [0]
    ) async throws -> ShellOutput {
        let output = try await run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        )
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
