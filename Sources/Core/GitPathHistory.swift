import Foundation

/// 「显示历史」（IDEA 的 Show History）只看一个文件或一个目录：提交历史列表只列动过它的提交。
///
/// 文件用 `git log --follow -- <路径>`，跨过改名接着往前找；目录不加 `--follow`（git 只认单个文件），
/// 列的是这个目录下任何文件动过的提交。
///
/// **`--follow` 与 `--skip` 一起用是坏的**（git 2.56 实测）：`--skip` 数的是遍历到的全部提交、不管动没动这个文件，
/// `-n 1 --skip 1` 返回的仍是第一个。`-n` 数的倒是输出的提交，所以翻页时拉 `skip + limit` 个、在这里丢掉前 `skip` 个。
/// 每翻一页都从头拉一遍，一页 100 个、文件的历史通常不长，代价可以接受；从最老那个的父提交续页不行——跨过改名点后路径得换成旧名。
public struct GitPathFilter: Hashable, Sendable {
    /// 相对**仓库根**的路径（项目根可能是仓库的子目录），`/` 分隔、不带结尾的 `/`。
    public let path: String
    public let isDirectory: Bool
    /// 界面上怎么称呼它（相对项目根的路径）。
    public let displayPath: String

    public init(path: String, isDirectory: Bool, displayPath: String? = nil) {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.path = trimmed
        self.isDirectory = isDirectory
        self.displayPath = displayPath ?? trimmed
    }

    /// 文件才跟踪改名；`--follow` 只接受单一路径，给目录会被 git 拒绝或静悄悄当成别的意思。
    public var follows: Bool { !isDirectory }

    /// 工具窗口横条上的标题：「Sources/Foo.swift 的历史」。
    public var title: String { displayPath + (isDirectory ? "/" : "") + " 的历史" }

    /// `git log` 的完整参数（含 `log`）。
    ///
    /// 文件：多带 `--name-status`，取每个提交里它叫什么（改名之前的提交里是旧名），格式前面加一个 0x1E 当记录开头——
    /// `-z` 下提交信息与 name-status 的字段都以 NUL 结尾，光靠 NUL 分不出哪里是下一个提交。
    public func logArguments(limit: Int, skip: Int) -> [String] {
        var arguments = ["log", "--date-order", "-z"]
        if follows {
            arguments += ["--format=" + GitPathHistoryParser.recordStart + GitLogParser.format, "--name-status",
                          "-n", String(skip + limit), "--follow"]
        } else {
            arguments += ["--format=" + GitLogParser.format, "-n", String(limit)]
            if skip > 0 { arguments += ["--skip", String(skip)] }
        }
        return arguments + ["--", path]
    }

    /// 某个提交的文件列表里，哪些是「它」：文件比的是它在那个提交里的名字（`pathAtCommit`，没有就用现在的名字），
    /// 重命名的那一条按新旧两个名字都认；目录是它下面的全部。
    public func matches(_ change: GitChange, pathAtCommit: String? = nil) -> Bool {
        if isDirectory {
            let prefix = path.isEmpty ? "" : path + "/"
            return change.path.hasPrefix(prefix) || (change.originalPath?.hasPrefix(prefix) ?? false)
        }
        let name = pathAtCommit ?? path
        return change.path == name || change.originalPath == name
    }

    /// 把「它」排到最前面，其余顺序不变。
    public func prioritized(_ changes: [GitChange], pathAtCommit: String? = nil) -> [GitChange] {
        let matching = changes.filter { matches($0, pathAtCommit: pathAtCommit) }
        guard !matching.isEmpty, matching.count < changes.count else { return changes }
        return matching + changes.filter { !matches($0, pathAtCommit: pathAtCommit) }
    }
}

/// 文件历史的一页：提交，以及（`--follow` 时）这个文件在每个提交里叫什么。
public struct GitPathHistoryPage: Equatable, Sendable {
    public let commits: [GitCommit]
    /// hash → 路径。目录历史、合并提交（`--name-status` 对合并提交不输出）不在里面。
    public let paths: [String: String]

    public init(commits: [GitCommit], paths: [String: String] = [:]) {
        self.commits = commits
        self.paths = paths
    }
}

/// `git log -z --format=<0x1E><GitLogParser.format> --name-status --follow` 的解析。
///
/// 每个提交是 `0x1E 字段… NUL [\n 状态 NUL 路径 NUL [新路径 NUL]]`：按 0x1E 切开，第一个 NUL 之前是提交本身
/// （提交信息里不会有 NUL、0x1E、0x1F），之后是 name-status。
public enum GitPathHistoryParser {
    public static let recordStart = "%x1e"
    static let recordSeparator: Character = "\u{1e}"

    public static func parse(_ data: Data, skip: Int = 0) -> GitPathHistoryPage {
        parse(String(decoding: data, as: UTF8.self), skip: skip)
    }

    /// `skip`：`--follow` 下 `--skip` 不可用，这里把前面几个丢掉（见 `GitPathFilter`）。
    public static func parse(_ text: String, skip: Int = 0) -> GitPathHistoryPage {
        var commits: [GitCommit] = []
        var paths: [String: String] = [:]
        for record in text.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let header: Substring
            let rest: Substring
            if let end = record.firstIndex(of: "\0") {
                header = record[..<end]
                rest = record[record.index(after: end)...]
            } else {
                header = record
                rest = ""
            }
            guard let commit = GitLogParser.parse(String(header) + "\0").first else { continue }
            commits.append(commit)
            let statusFields = rest.drop { $0 == "\n" }
            if let change = GitNameStatusParser.parse(String(statusFields)).first { paths[commit.hash] = change.path }
        }
        guard skip > 0 else { return GitPathHistoryPage(commits: commits, paths: paths) }
        let kept = Array(commits.dropFirst(skip))
        let keptHashes = Set(kept.map(\.hash))
        return GitPathHistoryPage(commits: kept, paths: paths.filter { keptHashes.contains($0.key) })
    }
}
