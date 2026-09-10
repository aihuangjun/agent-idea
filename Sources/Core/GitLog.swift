import Foundation

/// 一条提交。
public struct GitCommit: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    /// 作者写下这次改动的时间（`%at`）。rebase / cherry-pick 会保留它，所以它可能比提交落到本仓库的时间早很多。
    public let authorDate: Date
    /// 这次提交落到本仓库的时间（`%ct`）。`git log` 就是按它从新到旧排的，历史列表显示的也是它。
    public let commitDate: Date
    /// 第一行。
    public let subject: String
    /// 第一行之后的正文，已去掉首尾空白；没有则为空串。
    public let body: String

    public init(hash: String, shortHash: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date, commitDate: Date? = nil, subject: String, body: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.commitDate = commitDate ?? authorDate
        self.subject = subject
        self.body = body
    }

    public var isMerge: Bool { parents.count > 1 }

    /// 作者时间与提交时间差得够多（一分钟以上）才值得在详情里分开说；平时两者一样。
    public var authorDateDiffers: Bool { abs(authorDate.timeIntervalSince(commitDate)) >= 60 }

    /// 拿来算这次提交改了什么的基准：第一个父提交；根提交对比空树。
    public var diffBase: String { parents.first ?? GitClient.emptyTree }
}

/// `git log -z --format=<logFormat>` 的解析。记录之间以 NUL 分隔（`-z`），字段之间以 0x1F（单元分隔符）分隔——
/// 提交信息里什么字符都可能有，唯独这两个控制字符不会出现。
public enum GitLogParser {
    /// 字段顺序：全 hash、短 hash、父提交（空格分隔）、作者名、作者邮箱、作者时间（unix 秒）、提交时间（unix 秒）、主题、正文。
    public static let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%ct%x1f%s%x1f%b"
    static let fieldSeparator: Character = "\u{1f}"

    public static func parse(_ data: Data) -> [GitCommit] {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> [GitCommit] {
        text.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: fieldSeparator, maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8, !fields[0].isEmpty else { return nil }
            let parents = fields[2].split(separator: " ").map(String.init)
            let authorSeconds = TimeInterval(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let commitSeconds = TimeInterval(fields[6].trimmingCharacters(in: .whitespacesAndNewlines)) ?? authorSeconds
            let body = fields.count > 8 ? fields[8].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return GitCommit(
                hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                shortHash: fields[1],
                parents: parents,
                authorName: fields[3],
                authorEmail: fields[4],
                authorDate: Date(timeIntervalSince1970: authorSeconds),
                commitDate: Date(timeIntervalSince1970: commitSeconds),
                subject: fields[7],
                body: body
            )
        }
    }
}

/// `git diff --name-status -z -M <base> <commit>` 的解析：一次提交动了哪些文件。
///
/// 输出形如 `M\0path\0A\0path\0R100\0old\0new\0`。状态字母映射到 `ChangeKind`：
/// A 新增、M 修改、D 删除、R 重命名、C 复制（当新增）、T 类型变化（当修改）、U 冲突。
public enum GitNameStatusParser {
    public static func parse(_ data: Data) -> [GitChange] {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> [GitChange] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [GitChange] = []
        var index = 0
        // 每条记录：状态 + 路径；重命名/复制多一个原路径。字段不够就是输出被截断了，到此为止
        while index + 1 < fields.count, let letter = fields[index].first {
            if letter == "R" || letter == "C" {
                guard index + 2 < fields.count else { break }
                let original = fields[index + 1]
                let path = fields[index + 2]
                index += 3
                changes.append(GitChange(path: path, originalPath: letter == "R" ? original : nil, kind: letter == "R" ? .renamed : .added))
            } else {
                changes.append(GitChange(path: fields[index + 1], kind: kind(for: letter)))
                index += 2
            }
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func kind(for letter: Character) -> ChangeKind {
        switch letter {
        case "A": return .added
        case "D": return .deleted
        case "U": return .conflicted
        default: return .modified
        }
    }
}
