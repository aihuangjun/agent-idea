import Foundation

/// 合起来看的一段变更：`base` 那一版到 `target` 那一版之间改了什么（IDEA 历史里多选提交、Compare with Branch）。
///
/// 两头都是定死的完整 hash（`base` 可以是空树）：标签 id 由它拼出来，HEAD 之后再动，已经开着的区间 diff 也不跟着变。
/// diff 是两棵树之间的比较（`git diff base target`），不是逐个提交的补丁叠加。
public struct GitCommitRange: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// 历史里选中的一段提交：最老、最新那个的短 hash（都算在区间里）。
        case commits(oldest: String, newest: String)
        /// 当前分支与另一个分支比较：merge-base(分支, HEAD) → HEAD，即 `<分支>...HEAD`。
        case branch(String)
    }

    public let base: String
    public let target: String
    public let kind: Kind
    /// 区间里有几个提交：多选是选中的个数，分支比较是 `base..target` 的提交数。
    public let commitCount: Int
    /// 多选不连续时，夹在中间、没选上却仍然算进 diff 的提交数。
    public let skippedCount: Int

    public init(base: String, target: String, kind: Kind, commitCount: Int, skippedCount: Int = 0) {
        self.base = base
        self.target = target
        self.kind = kind
        self.commitCount = commitCount
        self.skippedCount = skippedCount
    }

    /// 标签 id、文件列表缓存用。与单个提交的 hash 不会撞（带 `..`）。
    public var id: String { base + ".." + target }

    public var branch: String? {
        if case .branch(let name) = kind { return name }
        return nil
    }

    /// 标签上那个小徽标：一眼看出这是一段区间而不是一次提交。
    public var badge: String {
        switch kind {
        case .commits(let oldest, let newest): return oldest + "…" + newest
        case .branch(let name): return "对比 " + name
        }
    }

    /// 面包屑、详情里的一句话说明在比什么。
    public var summary: String {
        switch kind {
        case .commits(let oldest, let newest): return "\(commitCount) 个提交（\(oldest) … \(newest)）"
        case .branch(let name): return "与 \(name) 比较"
        }
    }

    /// 详情 / 比较模式标题：「与 origin/master 比较 · 3 个提交 · 12 个文件」。文件列表还没到时不写文件数。
    public func title(fileCount: Int?) -> String {
        var parts: [String] = []
        if let branch { parts.append("与 \(branch) 比较") }
        parts.append("\(commitCount) 个提交")
        if let fileCount { parts.append("\(fileCount) 个文件") }
        return parts.joined(separator: " · ")
    }

    /// 需要额外说一句的情况；没有就是 nil。
    public var note: String? {
        switch kind {
        case .commits:
            guard skippedCount > 0 else { return nil }
            return "选中的提交不连续：比较的是最老到最新之间的全部变更，中间没选的 \(skippedCount) 个提交也算在内。"
        case .branch(let name):
            return commitCount == 0 ? "当前分支没有比 \(name) 多的提交。" : nil
        }
    }

    // MARK: - 选中 → 区间

    /// 历史列表里多选（`order` 是列表行序：新的在前）→ 区间。少于两个返回 nil（单选照旧看那一次提交）。
    ///
    /// target = 选中里最新（行序最靠前）的那个；base = 选中里最老那个的第一个父提交，根提交用空树。
    /// 选中不连续时中间没选的也在 diff 里（两棵树之间比），`skippedCount` 记着，详情里提示。
    public static func selection(_ selected: Set<String>, in commits: [GitCommit]) -> GitCommitRange? {
        let indices = commits.indices.filter { selected.contains(commits[$0].id) }
        guard indices.count > 1, let first = indices.first, let last = indices.last else { return nil }
        let newest = commits[first]
        let oldest = commits[last]
        return GitCommitRange(base: oldest.diffBase, target: newest.hash,
                              kind: .commits(oldest: oldest.shortHash, newest: newest.shortHash),
                              commitCount: indices.count, skippedCount: (last - first + 1) - indices.count)
    }

    /// 分支比较：merge-base 与 HEAD 都已解析成 hash。
    public static func branch(_ name: String, mergeBase: String, head: String, commitCount: Int) -> GitCommitRange {
        GitCommitRange(base: mergeBase, target: head, kind: .branch(name), commitCount: commitCount)
    }
}

/// 进入「与分支比较」失败的原因，给人看的。
public enum GitCompareError: Error, LocalizedError, Equatable {
    /// 两边没有共同祖先（不相关的历史）。
    case noCommonAncestor(String)
    /// 当前分支还没有提交。
    case noHead

    public var errorDescription: String? {
        switch self {
        case .noCommonAncestor(let branch): return "\(branch) 与当前分支没有共同的祖先提交，无法比较"
        case .noHead: return "当前分支还没有提交，无法比较"
        }
    }
}
