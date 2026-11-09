import CryptoKit
import Foundation

/// 一份文本的指纹：编辑器撤销历史只能装回到「记历史时的那份文本」上，靠它核对。
///
/// 口径：**行尾统一成 `\n` 之后（`LineEnding.normalized`）的 UTF-8 字节做 SHA-256**，十六进制小写。
/// - 要稳定：历史要落盘、重启后再比，`String.hashValue` 每个进程随机加盐，不能用。
/// - 要行尾归一：记历史时拿的是编辑器里的文字（只有 `\n`），保存之后、重开时手里的是磁盘上的样子（CRLF 文件是 `\r\n`）。
///   CodeMirror 按行 / 列记位置，换行符是哪种不影响历史里的位置，所以归一之后相等就能装。
/// - 其余一律按字节比（Unicode 等价但字节不同的也算不同）：宁可不装，也不能装错——`setHistory` 不校验，装错了 ⌘Z 会撕坏正文。
public enum TextFingerprint {
    public static func of(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(LineEnding.normalized(text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 编辑器撤销历史的落盘存档：关了标签、关了项目、退出重启之后还能 ⌘Z。
///
/// 按**文件**（规范化后的绝对路径）存一份 CodeMirror `getHistory()` 的 JSON 文本，连同它对应的那份文本的指纹（`TextFingerprint`）。
/// 目录里一个 `index.json`（路径 → 条目）加每条一个数据文件（随机名，路径变了只改索引不搬文件）。
/// 要索引是因为三件事没它做不了：按最近使用淘汰、目录改名 / 删除时按前缀换键、清掉孤儿文件。
///
/// 取的时候指纹对不上（文件被 Agent / 别的程序改过）就把这条删掉、不给。
/// 上限：单份超过 `maxRecordBytes` 不存；总量超过 `maxTotalBytes` 或条数超过 `maxRecords` 按最近使用淘汰；
/// `maxAge` 没用过的删掉；路径在磁盘上已经不在的（第一次读索引时查一遍）也删掉。
///
/// 只在主线程上用（会话都是 `@MainActor`），不加锁。写盘失败只记日志：撤销历史丢了不该打断编辑。
public final class EditorHistoryStore {
    public struct Limits: Sendable {
        public var maxRecordBytes: Int
        public var maxTotalBytes: Int
        public var maxRecords: Int
        public var maxAge: TimeInterval

        public init(maxRecordBytes: Int = 2 << 20, maxTotalBytes: Int = 50 << 20, maxRecords: Int = 500, maxAge: TimeInterval = 30 * 24 * 3600) {
            self.maxRecordBytes = maxRecordBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxRecords = maxRecords
            self.maxAge = maxAge
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// 数据文件名（在存档目录里）。
        public var file: String
        public var textHash: String
        public var bytes: Int
        public var lastUsed: Date

        public init(file: String, textHash: String, bytes: Int, lastUsed: Date) {
            self.file = file
            self.textHash = textHash
            self.bytes = bytes
            self.lastUsed = lastUsed
        }
    }

    struct Index: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    public static let indexFileName = "index.json"

    public let directory: URL
    public let limits: Limits
    private let now: () -> Date
    private let pathExists: (String) -> Bool
    private let indexStore: JSONFileStore<Index>
    private var loadedIndex: Index?
    /// 这次运行里写过的历史（路径 → 历史文本的哈希）：`saveAll` 很频繁，内容没变就不重写。只在内存里，进程内的哈希够用。
    private var written: [String: Int] = [:]

    public init(directory: URL, limits: Limits = Limits(), now: @escaping () -> Date = Date.init,
                pathExists: @escaping (String) -> Bool = { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }) {
        self.directory = directory
        self.limits = limits
        self.now = now
        self.pathExists = pathExists
        self.indexStore = JSONFileStore(url: directory.appendingPathComponent(Self.indexFileName))
    }

    /// 历史里有没有真正的编辑（CodeMirror 的历史里，光标移动只记选区，改动的事件才带 `changes`）。
    /// 只看过没改的文件不必占一条存档。
    public static func recordsEdits(_ historyJSON: String) -> Bool {
        historyJSON.contains("\"changes\"")
    }

    // MARK: - 存取

    /// 这个文件存着的历史。`textHash` 是此刻文件内容的指纹：对不上说明文件在别处被改过，这条作废（删掉）并返回 nil。
    public func load(path: String, textHash: String) -> String? {
        var index = currentIndex()
        guard let entry = index.entries[path] else { return nil }
        guard entry.textHash == textHash, now().timeIntervalSince(entry.lastUsed) <= limits.maxAge,
              let data = try? Data(contentsOf: fileURL(entry.file)), let json = String(data: data, encoding: .utf8) else {
            remove(path: path)
            return nil
        }
        index.entries[path]?.lastUsed = now()
        commit(index)
        return json
    }

    /// 存一份（覆盖这个文件原来的那份）。太大的不存，并且删掉旧的——旧的那份对应的文本多半也已经不是现在的样子了。
    public func save(path: String, textHash: String, history: String) {
        let bytes = history.utf8.count
        guard bytes <= limits.maxRecordBytes else {
            remove(path: path)
            return
        }
        var index = currentIndex()
        let fingerprint = history.hashValue
        if let existing = index.entries[path], existing.textHash == textHash, written[path] == fingerprint { return }
        let file = index.entries[path]?.file ?? UUID().uuidString + ".json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(history.utf8).write(to: fileURL(file), options: .atomic)
        } catch {
            Log.warn("undo", "保存 \(path) 的撤销历史失败：\(error)")
            return
        }
        index.entries[path] = Entry(file: file, textHash: textHash, bytes: bytes, lastUsed: now())
        written[path] = fingerprint
        enforceLimits(&index)
        commit(index)
    }

    /// 删掉一个路径的历史；是目录的话下面的一并删掉。
    public func remove(path: String) {
        var index = currentIndex()
        let doomed = index.entries.keys.filter { Self.isSameOrDescendant($0, of: path) }
        guard !doomed.isEmpty else { return }
        for key in doomed { drop(key, from: &index) }
        commit(index)
    }

    /// 文件（或目录）搬了家：历史跟着换路径（目录下的一并换）。目标路径上原有的记录被顶掉。
    public func move(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        var index = currentIndex()
        let moving = index.entries.keys.filter { Self.isSameOrDescendant($0, of: oldPath) }
        guard !moving.isEmpty else { return }
        // 先摘出来再放回去：不分大小写的改名（a → A）新旧前缀互相包含
        var carried: [(String, Entry)] = []
        for key in moving {
            guard let entry = index.entries.removeValue(forKey: key) else { continue }
            carried.append((newPath + key.dropFirst(oldPath.count), entry))
            if let fingerprint = written.removeValue(forKey: key) { written[newPath + key.dropFirst(oldPath.count)] = fingerprint }
        }
        for (key, entry) in carried {
            if let replaced = index.entries[key], replaced.file != entry.file { try? FileManager.default.removeItem(at: fileURL(replaced.file)) }
            index.entries[key] = entry
        }
        commit(index)
    }

    /// 存着的条目（按路径）。测试与诊断用。
    public var entries: [String: Entry] { currentIndex().entries }

    // MARK: - 清理

    /// 过期、超量的淘汰；`checkingPaths` 时路径已不在磁盘上的也删、目录里没登记的数据文件也删（第一次读索引时做一次）。
    public func prune(checkingPaths: Bool = false) {
        var index = currentIndex()
        if checkingPaths {
            for key in index.entries.keys where !pathExists(key) { drop(key, from: &index) }
            let referenced = Set(index.entries.values.map(\.file))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in files where name != Self.indexFileName && !referenced.contains(name) {
                try? FileManager.default.removeItem(at: fileURL(name))
            }
        }
        enforceLimits(&index)
        commit(index)
    }

    /// 过期的删掉，然后按最近使用从旧到新淘汰，直到条数与总量都在上限之内。纯逻辑，单测直接测它。
    public static func evictions(_ entries: [String: Entry], limits: Limits, now: Date) -> [String] {
        var doomed: [String] = []
        var kept: [(String, Entry)] = []
        for (key, entry) in entries {
            if now.timeIntervalSince(entry.lastUsed) > limits.maxAge { doomed.append(key) } else { kept.append((key, entry)) }
        }
        kept.sort { $0.1.lastUsed != $1.1.lastUsed ? $0.1.lastUsed < $1.1.lastUsed : $0.0 < $1.0 }
        var total = kept.reduce(0) { $0 + $1.1.bytes }
        var count = kept.count
        for (key, entry) in kept where count > limits.maxRecords || total > limits.maxTotalBytes {
            doomed.append(key)
            count -= 1
            total -= entry.bytes
        }
        return doomed
    }

    private func enforceLimits(_ index: inout Index) {
        for key in Self.evictions(index.entries, limits: limits, now: now()) { drop(key, from: &index) }
    }

    // MARK: - 内部

    private func currentIndex() -> Index {
        if let loadedIndex { return loadedIndex }
        loadedIndex = indexStore.load() ?? Index()
        // 第一次读进来：顺手清一遍（上次运行留下的过期、超量、文件已不在的、孤儿数据文件）
        prune(checkingPaths: true)
        return loadedIndex ?? Index()
    }

    private func drop(_ key: String, from index: inout Index) {
        guard let entry = index.entries.removeValue(forKey: key) else { return }
        written[key] = nil
        try? FileManager.default.removeItem(at: fileURL(entry.file))
    }

    private func commit(_ index: Index) {
        let changed = loadedIndex.map { $0.entries != index.entries } ?? true
        loadedIndex = index
        guard changed || !FileManager.default.fileExists(atPath: indexStore.url.path) else { return }
        // 空的而且盘上也没有就不建目录：从没存过历史的机器上不该冒出一个空目录
        if index.entries.isEmpty, !FileManager.default.fileExists(atPath: directory.path) { return }
        do {
            try indexStore.save(index)
        } catch {
            Log.warn("undo", "写撤销历史索引失败：\(error)")
        }
    }

    private func fileURL(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}
