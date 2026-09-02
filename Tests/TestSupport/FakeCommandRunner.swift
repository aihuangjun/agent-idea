import Core
import Foundation

/// 假的命令执行器：既能按顺序吐预设输出，也能按参数即时决定。所有测试共用这一份替身。
public final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let arguments: [String]
        public let directory: String?
    }

    public typealias Handler = @Sendable ([String], URL?) -> ShellOutput

    private let lock = NSLock()
    private var queued: [ShellOutput]
    private let handler: Handler?
    private(set) public var calls: [Call] = []

    /// 按调用顺序依次返回；用完之后返回空的成功输出。
    public init(responses: [ShellOutput]) {
        queued = responses
        handler = nil
    }

    /// 每次调用由闭包决定返回什么。
    public init(_ handler: @escaping Handler) {
        queued = []
        self.handler = handler
    }

    public func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?) async throws -> ShellOutput {
        record(Call(arguments: arguments, directory: currentDirectory?.path)) ?? handler!(arguments, currentDirectory)
    }

    /// 记一笔；预设队列模式下顺手取出下一份输出。
    private func record(_ call: Call) -> ShellOutput? {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
        guard handler == nil else { return nil }
        return queued.isEmpty ? ShellOutput(status: 0, standardOutput: Data(), standardError: "") : queued.removeFirst()
    }

    public func calls(startingWith command: String) -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.arguments).filter { $0.first == command }
    }
}

/// 造一份 stdout 为 `text` 的输出。
public func shellOutput(_ text: String, status: Int32 = 0, stderr: String = "") -> ShellOutput {
    ShellOutput(status: status, standardOutput: Data(text.utf8), standardError: stderr)
}

/// 线程安全的可变盒子：测试闭包里要改的状态放这儿（闭包必须是 Sendable）。
public final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    public init(_ value: T) { stored = value }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
