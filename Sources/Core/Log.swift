import Foundation

public enum LogLevel: String, Sendable {
    case info = "INFO "
    case warn = "WARN "
    case error = "ERROR"
}

/// 一个会自动轮转的日志文件。
///
/// 写入是同步的，刻意如此：日志的用处是「出了问题回头看」，异步排队意味着崩溃前的
/// 最后几行正好丢在队列里。句柄攥住不放（每行开一次文件会在滚动等热路径上掉帧），
/// 但每隔若干行按路径确认一次——句柄跟着 inode 走，日志被外部删掉后往里写不会报错。
public final class LogFile: @unchecked Sendable {
    public let fileURL: URL
    private let directory: URL
    private let maxBytes: Int
    private let backups: Int
    private let fileManager: FileManager
    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentBytes = 0
    private var linesSinceCheck = 0
    private static let revalidateEvery = 200

    public init(
        directory: URL,
        name: String = "agentidea.log",
        maxBytes: Int = 2 << 20,
        backups: Int = 2,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(name)
        self.maxBytes = maxBytes
        self.backups = max(0, backups)
        self.fileManager = fileManager
    }

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if handle != nil {
            linesSinceCheck += 1
            if linesSinceCheck >= Self.revalidateEvery {
                linesSinceCheck = 0
                if !fileManager.fileExists(atPath: fileURL.path) { closeHandle() }
            }
        }
        if currentBytes + data.count > maxBytes, currentBytes > 0 { rotate() }
        if handle == nil { openHandle() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentBytes += data.count
        } catch {
            closeHandle()
        }
    }

    private func openHandle() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return }
        currentBytes = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        linesSinceCheck = 0
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// `agentidea.log` → `agentidea.log.1` → `agentidea.log.2`，最老的丢掉。
    private func rotate() {
        closeHandle()
        guard backups > 0 else {
            try? fileManager.removeItem(at: fileURL)
            currentBytes = 0
            return
        }
        let oldest = fileURL.appendingPathExtension("\(backups)")
        try? fileManager.removeItem(at: oldest)
        for index in stride(from: backups - 1, through: 1, by: -1) {
            let from = fileURL.appendingPathExtension("\(index)")
            let to = fileURL.appendingPathExtension("\(index + 1)")
            if fileManager.fileExists(atPath: from.path) { try? fileManager.moveItem(at: from, to: to) }
        }
        try? fileManager.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
        currentBytes = 0
    }
}

/// 全应用共用的日志入口。没调过 `start` 时（测试进程）什么都不写。
public enum Log {
    private static let state = State()

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var file: LogFile?
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static var fileURL: URL? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.file?.fileURL
    }

    /// 启动时调用一次。`banner` 是第一行，通常写版本号与配置目录。
    public static func start(banner: String) {
        state.lock.lock()
        state.file = LogFile(directory: AppPaths.logDirectory)
        state.lock.unlock()
        write(.info, "app", "========== \(banner)")
    }

    public static func info(_ category: String, _ message: String) { write(.info, category, message) }
    public static func warn(_ category: String, _ message: String) { write(.warn, category, message) }
    public static func error(_ category: String, _ message: String) { write(.error, category, message) }

    private static func write(_ level: LogLevel, _ category: String, _ message: String) {
        state.lock.lock()
        let file = state.file
        state.lock.unlock()
        file?.append("\(formatter.string(from: Date())) \(level.rawValue) [\(category)] \(message)")
    }
}
