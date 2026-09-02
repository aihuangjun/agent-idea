import Foundation

/// 一个路径相对 HEAD 发生了什么。口径与 IDEA 提交窗口的分组一致。
public enum ChangeKind: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case added
    case modified
    case deleted
    case renamed
    case conflicted
    /// 未纳入版本管理（IDEA 叫 Unversioned）。
    case untracked

    /// 一个目录里同时有几种变化时，它显示哪一种：冲突 > 删除 > 修改 > 重命名 > 新增 > 未跟踪。
    /// 排序只影响目录着色，与提交无关。
    public var precedence: Int {
        switch self {
        case .conflicted: return 6
        case .deleted: return 5
        case .modified: return 4
        case .renamed: return 3
        case .added: return 2
        case .untracked: return 1
        }
    }

    public var label: String {
        switch self {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        case .renamed: return "重命名"
        case .conflicted: return "冲突"
        case .untracked: return "未跟踪"
        }
    }
}

/// 一条变更。路径相对仓库根，用 `/` 分隔（git 的口径）。
public struct GitChange: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// 重命名时的原路径。
    public let originalPath: String?
    public let kind: ChangeKind
    /// 暂存区有改动（`git add` 过）。只读阅读器不区分暂存/未暂存的 diff，但列表上标一下。
    public let isStaged: Bool
    /// 工作区有改动。
    public let isUnstaged: Bool

    public init(path: String, originalPath: String? = nil, kind: ChangeKind, isStaged: Bool = false, isUnstaged: Bool = true) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.isStaged = isStaged
        self.isUnstaged = isUnstaged
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

/// 分支信息。
public struct GitBranch: Equatable, Hashable, Sendable {
    /// 分支名；游离 HEAD 时是短提交号。
    public let name: String
    public let isDetached: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// 还没有任何提交的仓库。
    public let isUnborn: Bool

    public init(name: String, isDetached: Bool = false, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, isUnborn: Bool = false) {
        self.name = name
        self.isDetached = isDetached
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isUnborn = isUnborn
    }
}

/// `git status --porcelain=v2 -z --branch --untracked-files=all --ignored=matching` 的解析结果。
public struct GitSnapshot: Equatable, Sendable {
    public let branch: GitBranch
    public let changes: [GitChange]
    /// 被忽略的路径。目录带尾部 `/`（git 的写法），文件不带。
    public let ignored: [String]

    public init(branch: GitBranch, changes: [GitChange], ignored: [String]) {
        self.branch = branch
        self.changes = changes
        self.ignored = ignored
    }

    public static let empty = GitSnapshot(branch: GitBranch(name: "", isUnborn: true), changes: [], ignored: [])
}

/// porcelain v2 解析。用 `-z`：路径里有空格、中文、引号时 v1 的转义规则一堆坑，NUL 分隔干净得多。
public enum GitStatusParser {
    public static func parse(_ data: Data) -> GitSnapshot {
        let text = String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    public static func parse(_ text: String) -> GitSnapshot {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)

        var head = ""
        var oid = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes: [GitChange] = []
        var ignored: [String] = []

        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1

            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": oid = parts[1]
                case "branch.head": head = parts[1]
                case "branch.upstream": upstream = parts[1]
                case "branch.ab":
                    for token in parts[1].split(separator: " ") {
                        if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }

            if record.hasPrefix("? ") {
                changes.append(GitChange(path: String(record.dropFirst(2)), kind: .untracked, isStaged: false, isUnstaged: true))
                continue
            }
            if record.hasPrefix("! ") {
                ignored.append(String(record.dropFirst(2)))
                continue
            }

            // 1 XY sub mH mI mW hH hI path
            // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
            // u XY sub m1 m2 m3 mW h1 h2 h3 path
            let parts = record.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[1].count == 2 else { continue }
            let xy = Array(parts[1])
            let indexStatus = xy[0]
            let worktreeStatus = xy[1]

            switch parts[0] {
            case "1":
                guard parts.count >= 9 else { continue }
                let path = parts[8...].joined(separator: " ")
                changes.append(GitChange(
                    path: path,
                    kind: kind(index: indexStatus, worktree: worktreeStatus),
                    isStaged: indexStatus != ".",
                    isUnstaged: worktreeStatus != "."
                ))
            case "2":
                guard parts.count >= 10, index < fields.count else { continue }
                let path = parts[9...].joined(separator: " ")
                let original = fields[index]
                index += 1
                changes.append(GitChange(
                    path: path,
                    originalPath: original,
                    kind: .renamed,
                    isStaged: indexStatus != ".",
                    isUnstaged: worktreeStatus != "."
                ))
            case "u":
                guard parts.count >= 11 else { continue }
                let path = parts[10...].joined(separator: " ")
                changes.append(GitChange(path: path, kind: .conflicted, isStaged: true, isUnstaged: true))
            default:
                continue
            }
        }

        let isUnborn = oid == "(initial)"
        let isDetached = head == "(detached)"
        let name: String
        if isDetached {
            name = String(oid.prefix(7))
        } else {
            name = head
        }
        let branch = GitBranch(name: name, isDetached: isDetached, upstream: upstream, ahead: ahead, behind: behind, isUnborn: isUnborn)
        return GitSnapshot(branch: branch, changes: changes, ignored: ignored)
    }

    /// 把 XY 两个字母合成一个给人看的种类。工作区那一位优先：用户看到的是磁盘上的样子。
    static func kind(index: Character, worktree: Character) -> ChangeKind {
        if index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") {
            return .conflicted
        }
        if worktree == "D" || (index == "D" && worktree == ".") { return .deleted }
        if index == "A" { return worktree == "D" ? .deleted : .added }
        if index == "R" || worktree == "R" { return .renamed }
        if index == "C" || worktree == "C" { return .added }
        return .modified
    }
}

/// 把一份快照整理成「给一个路径查状态」的索引：文件自己的状态、目录聚合的状态、是否被忽略。
///
/// 路径一律用相对仓库根的 `/` 分隔形式，不带前导 `/`。
public struct GitStatusIndex: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case change(ChangeKind)
        case ignored
    }

    private let files: [String: ChangeKind]
    /// 目录 → 其下（任意深度）变更里优先级最高的那一种。
    private let directories: [String: ChangeKind]
    private let ignoredFiles: Set<String>
    private let ignoredDirectories: Set<String>

    public static let empty = GitStatusIndex(snapshot: .empty)

    public init(snapshot: GitSnapshot) {
        var files: [String: ChangeKind] = [:]
        var directories: [String: ChangeKind] = [:]
        for change in snapshot.changes {
            files[change.path] = change.kind
            var directory = (change.path as NSString).deletingLastPathComponent
            while !directory.isEmpty {
                if let existing = directories[directory], existing.precedence >= change.kind.precedence {
                    // 已经记了更强的，但更上层的祖先仍要继续走
                } else {
                    directories[directory] = change.kind
                }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        var ignoredFiles: Set<String> = []
        var ignoredDirectories: Set<String> = []
        for path in snapshot.ignored {
            if path.hasSuffix("/") {
                ignoredDirectories.insert(String(path.dropLast()))
            } else {
                ignoredFiles.insert(path)
            }
        }
        self.files = files
        self.directories = directories
        self.ignoredFiles = ignoredFiles
        self.ignoredDirectories = ignoredDirectories
    }

    public var changedFileCount: Int { files.count }

    public func status(of relativePath: String, isDirectory: Bool) -> Status? {
        if isIgnored(relativePath, isDirectory: isDirectory) { return .ignored }
        if isDirectory {
            return directories[relativePath].map(Status.change)
        }
        return files[relativePath].map(Status.change)
    }

    public func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        if isDirectory {
            if ignoredDirectories.contains(relativePath) { return true }
        } else if ignoredFiles.contains(relativePath) || ignoredDirectories.contains(relativePath) {
            return true
        }
        // 祖先目录被忽略，后代全算忽略
        var directory = (relativePath as NSString).deletingLastPathComponent
        while !directory.isEmpty {
            if ignoredDirectories.contains(directory) { return true }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return false
    }
}

/// 变更列表的分组（IDEA 提交窗口的样子）：已跟踪的改动一组，未跟踪的一组。
public struct ChangeGroups: Equatable, Sendable {
    public let tracked: [GitChange]
    public let untracked: [GitChange]

    public init(changes: [GitChange]) {
        let sortedChanges = changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        tracked = sortedChanges.filter { $0.kind != .untracked }
        untracked = sortedChanges.filter { $0.kind == .untracked }
    }

    public var total: Int { tracked.count + untracked.count }
}
