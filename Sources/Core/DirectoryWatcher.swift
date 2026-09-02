import CoreServices
import Foundation

/// 递归监听一个目录，文件有变化就回调（带上变了的路径）。
///
/// 用 FSEvents 而不是 `DispatchSource`：后者一个 fd 只盯一个目录，工作区几千个目录开不起。
/// 回调在指定队列上，调用方自己做去抖——Agent 一次改动会连着触发几十个事件。
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let url: URL
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "agentidea.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(url: URL, latency: TimeInterval = 0.4, handler: @escaping Handler) {
        self.url = url
        self.latency = latency
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
            latency,
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

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// 哪些路径的变化值得刷新。
    ///
    /// `.git/` 内部大多是对象与锁文件的噪音，但 `index`、`HEAD`、`refs/` 变了意味着
    /// 用户在终端里 add/commit/切分支了，得刷新。`index.lock` 是每次 git 命令的副产物，不算。
    public static func isRelevant(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return true }
        let inside = path[range.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/") || inside == "MERGE_HEAD"
    }
}
