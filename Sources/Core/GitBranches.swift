import Foundation

/// 仓库里的分支：本地的、远程跟踪的，以及远程的默认分支（`origin/HEAD` 指向的那个，通常是 `origin/master`）。
/// 状态栏的分支弹窗（IDEA 的 Git Branches）、「没有上游时从哪儿同步」都看它。
public struct GitBranchList: Equatable, Sendable {
    public struct Local: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        /// 跟踪的远程分支（`origin/master`），没有是 nil。
        public let upstream: String?
        public let isCurrent: Bool

        public init(name: String, upstream: String? = nil, isCurrent: Bool = false) {
            self.name = name
            self.upstream = upstream
            self.isCurrent = isCurrent
        }
    }

    /// 当前分支排最前，其余按名字。
    public let local: [Local]
    /// 远程跟踪分支（`origin/x`），默认分支排最前，其余按名字；不含 `origin/HEAD` 这个符号引用。
    public let remote: [String]
    /// 远程的默认分支（`origin/master`）。没有远程、或者远程没告诉我们默认分支、也没有 main / master 时为 nil。
    public let defaultRemoteBranch: String?
    /// 配置的远程仓库名（`origin`）。
    public let remotes: [String]

    public init(local: [Local], remote: [String], defaultRemoteBranch: String?, remotes: [String]) {
        self.local = local
        self.remote = remote
        self.defaultRemoteBranch = defaultRemoteBranch
        self.remotes = remotes
    }

    public var current: Local? { local.first(where: \.isCurrent) }

    public func local(named name: String) -> Local? { local.first { $0.name == name } }

    /// 新分支、同步时优先用的远程：有 `origin` 就是它，否则第一个。
    public var preferredRemote: String? { remotes.contains("origin") ? "origin" : remotes.first }

    /// 远程分支签出到本地时用的名字：去掉远程名前缀（`origin/feat/a` → `feat/a`）。远程名里也可能有 `/`，按最长的前缀去。
    public func localName(for remoteBranch: String) -> String {
        let prefix = remotes.map { $0 + "/" }.filter { remoteBranch.hasPrefix($0) }.max { $0.count < $1.count }
        return prefix.map { String(remoteBranch.dropFirst($0.count)) } ?? remoteBranch
    }

    /// 当前分支没有上游时，建议它跟踪哪个远程分支：远程有同名分支就是它（推过但没带 -u），否则远程的默认分支（IDEA 也默认 origin/master）。
    public func suggestedUpstream(for branch: String) -> String? {
        if let remote = preferredRemote, self.remote.contains(remote + "/" + branch) { return remote + "/" + branch }
        return defaultRemoteBranch
    }

    /// `git for-each-ref` 用的格式：完整引用名、跟踪的上游、是不是当前分支（`*`），字段之间用 0x1f 分开，一行一个。
    public static let forEachRefFormat = "%(refname)%1f%(upstream:short)%1f%(HEAD)"

    /// 解析 `git for-each-ref --format=<forEachRefFormat> refs/heads refs/remotes` 的输出。
    /// `remoteHead` 是 `git symbolic-ref --short refs/remotes/<远程>/HEAD` 的结果（远程的默认分支），拿不到时退回 main / master。
    public static func parse(_ text: String, remotes: [String], remoteHead: String?) -> GitBranchList {
        var local: [Local] = []
        var remote: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard let ref = fields.first else { continue }
            if ref.hasPrefix("refs/heads/") {
                let upstream = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
                local.append(Local(name: String(ref.dropFirst("refs/heads/".count)), upstream: upstream, isCurrent: fields.count > 2 && fields[2] == "*"))
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst("refs/remotes/".count))
                if !name.hasSuffix("/HEAD") { remote.append(name) }
            }
        }
        let preferred = remotes.contains("origin") ? "origin" : remotes.first
        let defaultBranch = remoteHead.flatMap { remote.contains($0) ? $0 : nil }
            ?? preferred.flatMap { remoteName in ["main", "master"].map { remoteName + "/" + $0 }.first(where: remote.contains) }
        local.sort { ($0.isCurrent ? 0 : 1, $0.name) < ($1.isCurrent ? 0 : 1, $1.name) }
        remote.sort { ($0 == defaultBranch ? 0 : 1, $0) < ($1 == defaultBranch ? 0 : 1, $1) }
        return GitBranchList(local: local, remote: remote, defaultRemoteBranch: defaultBranch, remotes: remotes)
    }
}

/// 新分支名能不能用。规则是 `git check-ref-format --branch` 的常用子集，给对话框边敲边提示；最终以 git 为准。
public enum GitBranchName {
    public enum Problem: Equatable, Sendable {
        case empty
        case invalid
        case exists

        public var message: String {
            switch self {
            case .empty: return "分支名不能为空"
            case .invalid: return "git 不接受这个分支名（不能有空格和 ~ ^ : ? * [ \\，不能以 - 或 . 开头，不能有 .. 或 //，不能以 / 或 .lock 结尾）"
            case .exists: return "已经有同名的本地分支"
            }
        }
    }

    public static func problem(_ name: String, existing: [String]) -> Problem? {
        if name.isEmpty { return .empty }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.whitespacesAndNewlines)
        if name.rangeOfCharacter(from: forbidden) != nil || name.hasPrefix("-") || name == "@" || name.contains("..") || name.contains("//")
            || name.contains("@{") || name.hasSuffix("/") || name.hasSuffix(".") || name.hasSuffix(".lock")
            || name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix(".") }) {
            return .invalid
        }
        if existing.contains(name) { return .exists }
        return nil
    }
}
