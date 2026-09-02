import Foundation

/// 文件搜索索引里的一项：相对项目根的路径（`/` 分隔）。
public struct FileSearchEntry: Equatable, Hashable, Sendable {
    public let path: String
    public let name: String
    public var directory: String { (path as NSString).deletingLastPathComponent }
    /// 建索引时算好的小写字符数组：每敲一个字要扫全部条目，不能在那时再转。
    public let lowercasedName: [Character]
    public let lowercasedPath: [Character]

    public init(path: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.lowercasedName = Array(name.lowercased())
        self.lowercasedPath = Array(path.lowercased())
    }

    public static func == (lhs: FileSearchEntry, rhs: FileSearchEntry) -> Bool { lhs.path == rhs.path }
    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// 遍历项目目录建搜索索引。只收文件，不收目录。
///
/// 跳过 `.git`、`.DS_Store`（同目录树），以及 `isExcluded` 说不要的（调用方拿 git 的忽略规则来判——
/// `node_modules`、构建产物这些既慢又没人搜）。超过 `limit` 条就停，避免在一个巨型目录里转几十秒。
public enum FileIndexer {
    public static let defaultLimit = 100_000

    /// - Parameters:
    ///   - prefix: 只索引根下的这个子目录时，条目路径前面要带的前缀（增量重扫一个目录用）。
    ///   - shouldStop: 每列完一个目录问一次，说停就停（项目关掉、索引作废）。
    public static func index(
        root: URL,
        prefix: String = "",
        limit: Int = defaultLimit,
        fileManager: FileManager = .default,
        shouldStop: () -> Bool = { false },
        isExcluded: (_ relativePath: String, _ isDirectory: Bool) -> Bool
    ) -> [FileSearchEntry] {
        var entries: [FileSearchEntry] = []
        var pendingDirectories: [(url: URL, relative: String)] = [(root, prefix)]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        while let (directory, relative) = pendingDirectories.popLast(), entries.count < limit, !shouldStop() {
            guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: []) else { continue }
            for item in contents {
                let name = item.lastPathComponent
                if DirectoryLister.hiddenNames.contains(name) { continue }
                let values = try? item.resourceValues(forKeys: keys)
                let relativePath = relative.isEmpty ? name : relative + "/" + name
                var isDirectory = values?.isDirectory ?? false
                if values?.isSymbolicLink == true {
                    // 指向目录的符号链接不进去（可能绕回来形成环）；指向文件的当普通文件收
                    var targetIsDirectory: ObjCBool = false
                    let target = item.resolvingSymlinksInPath().path
                    isDirectory = fileManager.fileExists(atPath: target, isDirectory: &targetIsDirectory) && targetIsDirectory.boolValue
                    if isDirectory { continue }
                }
                if isExcluded(relativePath, isDirectory) { continue }
                if isDirectory {
                    pendingDirectories.append((directory.appendingPathComponent(name, isDirectory: true), relativePath))
                } else {
                    entries.append(FileSearchEntry(path: relativePath))
                    if entries.count >= limit { break }
                }
            }
        }
        return entries
    }
}

/// 一条搜索结果。
public struct FileSearchMatch: Equatable, Sendable {
    public let entry: FileSearchEntry
    public let score: Int
    /// 文件名里命中的字符下标（按 Character 计），给高亮用。按路径命中的为空。
    public let matchedNameIndices: [Int]

    public init(entry: FileSearchEntry, score: Int, matchedNameIndices: [Int]) {
        self.entry = entry
        self.score = score
        self.matchedNameIndices = matchedNameIndices
    }
}

/// 按文件名/路径找文件，照 IDEA 的 Go to File 的手感：
///
/// - 不分大小写；
/// - 先按文件名匹配：全等 > 前缀 > 包含 > 子序列（`amdl` 能找到 `AppModel.swift`），子序列里落在单词开头的字符加分；
/// - 查询里带 `/` 时按整条路径匹配；文件名匹配不上的再退到路径包含；
/// - 同分的短名字在前，再按路径字母序。
public enum FileSearch {
    /// `shouldStop` 每扫 1024 条问一次；说停就返回空（结果反正会被丢掉）。
    public static func search(_ rawQuery: String, in entries: [FileSearchEntry], limit: Int = 200, shouldStop: () -> Bool = { false }) -> [FileSearchMatch] {
        let query = Array(rawQuery.trimmingCharacters(in: .whitespaces).lowercased())
        guard !query.isEmpty else { return [] }
        let byPath = query.contains("/")
        var matches: [FileSearchMatch] = []
        matches.reserveCapacity(min(limit * 4, 1024))
        for (offset, entry) in entries.enumerated() {
            if offset % 1024 == 1023, shouldStop() { return [] }
            if let match = score(entry, query: query, byPath: byPath) { matches.append(match) }
        }
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lowercasedName.count != rhs.entry.lowercasedName.count { return lhs.entry.lowercasedName.count < rhs.entry.lowercasedName.count }
            return lhs.entry.path < rhs.entry.path
        }
        return Array(matches.prefix(limit))
    }

    static func score(_ entry: FileSearchEntry, query: [Character], byPath: Bool) -> FileSearchMatch? {
        let name = entry.lowercasedName
        if !byPath {
            if name == query { return FileSearchMatch(entry: entry, score: 1000, matchedNameIndices: Array(name.indices)) }
            if name.starts(with: query) { return FileSearchMatch(entry: entry, score: 800, matchedNameIndices: Array(0..<query.count)) }
            if let start = firstRange(of: query, in: name) {
                return FileSearchMatch(entry: entry, score: 600 - min(start, 100), matchedNameIndices: Array(start..<(start + query.count)))
            }
            if let (indices, bonus) = subsequence(query, in: name) {
                return FileSearchMatch(entry: entry, score: 300 + bonus - min(indices.last! - indices.first! - query.count + 1, 100), matchedNameIndices: indices)
            }
        }
        let path = entry.lowercasedPath
        if let start = firstRange(of: query, in: path) { return FileSearchMatch(entry: entry, score: 200 - min(path.count - start, 100) / 10, matchedNameIndices: []) }
        if let (indices, bonus) = subsequence(query, in: path) {
            return FileSearchMatch(entry: entry, score: 100 + bonus / 2 - min(indices.last! - indices.first! - query.count + 1, 90), matchedNameIndices: [])
        }
        return nil
    }

    static func firstRange(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        outer: for start in 0...(haystack.count - needle.count) {
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] { continue outer }
            return start
        }
        return nil
    }

    /// 子序列匹配。先试「每个字符尽量落在单词开头」的挑法（`amdl` → **A**pp**M**o**d**e**l**），
    /// 挑不通（往后跳过头、后面的字符没处落）再退回最靠左的贪心匹配。返回命中的下标与「单词开头命中数 × 20」的加分。
    static func subsequence(_ needle: [Character], in haystack: [Character]) -> (indices: [Int], bonus: Int)? {
        guard let indices = pick(needle, in: haystack, preferWordStarts: true) ?? pick(needle, in: haystack, preferWordStarts: false) else { return nil }
        let bonus = indices.filter { isWordStart(haystack, at: $0) }.count * 20
        return (indices, bonus)
    }

    private static func pick(_ needle: [Character], in haystack: [Character], preferWordStarts: Bool) -> [Int]? {
        var indices: [Int] = []
        var position = 0
        for character in needle {
            var found: Int?
            var probe = position
            while probe < haystack.count {
                if haystack[probe] == character {
                    if found == nil { found = probe }
                    if !preferWordStarts || isWordStart(haystack, at: probe) { found = probe; break }
                }
                probe += 1
            }
            guard let index = found else { return nil }
            indices.append(index)
            position = index + 1
        }
        return indices
    }

    static func isWordStart(_ text: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        return previous == "_" || previous == "-" || previous == "." || previous == "/" || previous == " "
    }
}
