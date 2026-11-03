import CoreServices
import Darwin
import Foundation

/// 递归监听一个目录，文件有变化就回调（带上变了的路径）。
///
/// 用 FSEvents 而不是 `DispatchSource`：后者一个 fd 只盯一个目录，工作区几千个目录开不起。
/// 回调在内部的后台队列上，调用方自己跳回主线程并做去抖——Agent 一次改动会连着触发几十个事件。
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let url: URL
    /// FSEvents 攒事件的时间；调用方还会再去抖一次，这里不必太长。
    private static let latency: TimeInterval = 0.4
    private let handler: Handler
    private let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "agentidea.fsevents", qos: .utility)
        queue.setSpecific(key: DirectoryWatcher.queueKey, value: true)
        return queue
    }()
    private var stream: FSEventStreamRef?

    public init(url: URL, handler: @escaping Handler) {
        self.url = url
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                var changed: [String] = []
                changed.reserveCapacity(count)
                for index in 0..<count {
                    if let path = array[index] as? String { changed.append(path) }
                }
                watcher.handler(changed)
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// 停掉监听。**在回调队列上同步做**：回调里用的是 `passUnretained(self)`，若停的那一刻
    /// 正有一次回调在 utility 队列上跑，它会读到一个正在释放的 self。排到同一队列上就不会撞。
    public func stop() {
        guard stream != nil else { return }
        let work = { [self] in
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    /// 哪些路径的变化值得刷新。
    ///
    /// `.git/` 内部大多是对象与锁文件的噪音，但 `index`、`HEAD`、`refs/` 变了意味着
    /// 用户在终端里 add/commit/切分支了，得刷新。`index.lock` 是每次 git 命令的副产物，不算。
    public static func isRelevant(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return true }
        return isRelevantGitPath(String(path[range.upperBound...]))
    }

    /// 相对于实际 git-dir / common-dir 的路径，兼容 worktree 与自定义 git 目录。
    public static func isRelevantGitPath(_ inside: String) -> Bool {
        if inside.hasSuffix(".lock") { return false }
        return inside.isEmpty || ["index", "HEAD", "refs", "packed-refs", "config", "MERGE_HEAD", "rebase-merge", "rebase-apply"].contains(inside)
            || inside.hasPrefix("refs/") || inside.hasPrefix("rebase-merge/") || inside.hasPrefix("rebase-apply/")
    }

}

/// FSEvents 返回 /private/tmp、/private/var 等真实路径，Foundation URL 可能是 /tmp、
/// /var 或符号链接。只对存在的根目录调用 realpath：事件里的锁文件可能已经被删掉或改名，
/// 对事件路径调用 URL.resolvingSymlinks 会因文件存在与否得到不同的前缀。
public struct GitMetadataEventFilter: Sendable {
    private let roots: [String]

    public init(directory: URL) {
        let original = directory.path
        if let physical = realpath(original, nil) {
            defer { free(physical) }
            roots = Array(Set([original, String(cString: physical)]))
        } else {
            roots = [original]
        }
    }

    public func isRelevant(_ path: String) -> Bool {
        for root in roots {
            if path == root { return true }
            let prefix = root + "/"
            if path.hasPrefix(prefix) {
                return DirectoryWatcher.isRelevantGitPath(String(path.dropFirst(prefix.count)))
            }
        }
        return false
    }
}
