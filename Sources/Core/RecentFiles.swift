import Foundation

/// 一个项目最近打开过的文件（IDEA 的 Recent Files，⌘E）。纯值类型，新的在前。
///
/// 与「后退 / 前进」的 `NavigationHistory` 是两回事：那个跟着标签走、关标签就抹掉；这个记的是「打开过」，
/// 关掉的文件照样在里面——⌘E 最常用来找回刚关掉的那个。路径相对项目根（项目搬家也还认），持久化由调用方做。
public struct RecentFiles: Equatable, Sendable {
    public struct Entry: Equatable, Codable, Sendable {
        /// 相对项目根，`/` 分隔。
        public let path: String
        public let openedAt: Date

        public init(path: String, openedAt: Date) {
            self.path = path
            self.openedAt = openedAt
        }

        /// 给搜索打分、列表显示用。
        public var searchEntry: FileSearchEntry { FileSearchEntry(path: path) }
    }

    public static let defaultCapacity = 50

    /// 新的在前，同一路径只出现一次。
    public private(set) var entries: [Entry]
    public let capacity: Int

    public init(entries: [Entry] = [], capacity: Int = RecentFiles.defaultCapacity) {
        self.capacity = max(1, capacity)
        // 存档可能是旧版本写的、被手改过：照规矩整理一遍（按时间排、去重、截断）
        var seen = Set<String>()
        self.entries = entries
            .enumerated()
            .sorted { $0.element.openedAt != $1.element.openedAt ? $0.element.openedAt > $1.element.openedAt : $0.offset < $1.offset }
            .map(\.element)
            .filter { !$0.path.isEmpty && seen.insert($0.path).inserted }
        if self.entries.count > self.capacity { self.entries.removeLast(self.entries.count - self.capacity) }
    }

    /// 打开（或切到）了这个文件：挪到最前面，超出上限丢最老的。
    public mutating func record(_ path: String, at date: Date = Date()) {
        guard !path.isEmpty else { return }
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, openedAt: date), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// 去掉满足条件的（磁盘上已经没有的）。返回有没有去掉东西。
    @discardableResult
    public mutating func removeAll(where shouldRemove: (Entry) -> Bool) -> Bool {
        let before = entries.count
        entries.removeAll(where: shouldRemove)
        return entries.count != before
    }

    /// 文件或目录改名 / 移动了：它自己和它下面的条目都换成新路径，时间与位置不变。新路径原来就有条目的话留排前的那个。
    /// 返回有没有改动。
    @discardableResult
    public mutating func rename(from oldPath: String, to newPath: String) -> Bool {
        var changed = false
        let renamed = entries.map { entry -> Entry in
            guard let path = Self.rewrite(entry.path, from: oldPath, to: newPath) else { return entry }
            changed = true
            return Entry(path: path, openedAt: entry.openedAt)
        }
        guard changed else { return false }
        var seen = Set<String>()
        entries = renamed.filter { seen.insert($0.path).inserted }
        return true
    }

    /// 弹窗里列哪些：去掉当前文件（IDEA 默认选中第二项，就是为了来回切；这里干脆不列它，选中的第一项就是上一个文件）。
    public func candidates(excluding current: String?) -> [Entry] {
        guard let current else { return entries }
        return entries.filter { $0.path != current }
    }

    /// 输入即过滤：打分沿用查找文件（`FileSearch`：文件名全等 > 前缀 > 包含 > 子序列，带 `/` 按路径），
    /// 同分的保持最近打开的顺序。空查询原样返回（按最近排）。
    public static func filter(_ entries: [Entry], query rawQuery: String) -> [FileSearchMatch] {
        let query = Array(rawQuery.trimmingCharacters(in: .whitespaces).lowercased())
        guard !query.isEmpty else {
            return entries.map { FileSearchMatch(entry: $0.searchEntry, score: 0, matchedNameIndices: []) }
        }
        let byPath = query.contains("/")
        return entries.enumerated()
            .compactMap { offset, entry in FileSearch.score(entry.searchEntry, query: query, byPath: byPath).map { (offset, $0) } }
            .sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0 < $1.0 }
            .map(\.1)
    }

    static func rewrite(_ path: String, from oldPath: String, to newPath: String) -> String? {
        if path == oldPath { return newPath }
        guard path.hasPrefix(oldPath + "/") else { return nil }
        return newPath + path.dropFirst(oldPath.count)
    }
}
