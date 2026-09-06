import Foundation

/// 与远程同步一次（`git fetch` + `git rebase <上游>`）的结果，也就是 IDEA 的 Update Project。
///
/// 数字是 rebase **之前**算的：`pulled` 是上游比本地多出来的提交（这次拉下来几个），
/// `replayed` 是本地比上游多出来的提交（这几个会被重放到上游最新提交之上）。
public struct GitSyncResult: Equatable, Sendable {
    /// 上游分支名，例如 `origin/main`。
    public let upstream: String
    public let pulled: Int
    public let replayed: Int

    public init(upstream: String, pulled: Int, replayed: Int) {
        self.upstream = upstream
        self.pulled = pulled
        self.replayed = replayed
    }

    /// 上游没有新东西时不跑 rebase：本地什么都没动。
    public var didRebase: Bool { pulled > 0 }

    /// 给用户看的一句话。
    public var summary: String {
        switch (pulled, replayed) {
        case (0, 0): return "已经是最新的（\(upstream)）"
        case (0, let ahead): return "已经是最新的，本地领先 \(upstream) \(ahead) 个提交"
        case (let behind, 0): return "已从 \(upstream) 拉取 \(behind) 个提交"
        case (let behind, let ahead): return "已从 \(upstream) 拉取 \(behind) 个提交，本地 \(ahead) 个提交重放在它们之上"
        }
    }
}

/// 同步没能走完的几种情形。都不留下中间状态：要么没开始，要么已经回滚干净（`recovered`）。
public enum GitSyncError: Error, LocalizedError, Equatable {
    /// 仓库还没有提交。
    case unborn
    /// 当前分支没有跟踪远程分支（也包括游离 HEAD）。
    case noUpstream(branch: String)
    /// rebase 没走完（多半是冲突）。`recovered` 表示已经 `rebase --abort` 回到同步前的样子。
    case rebaseFailed(message: String, recovered: Bool)

    public var errorDescription: String? {
        switch self {
        case .unborn:
            return "仓库还没有任何提交，没有可同步的分支"
        case .noUpstream(let branch):
            return "\(branch) 没有跟踪远程分支，先 git push -u 建立上游再同步"
        case .rebaseFailed(let message, let recovered):
            let tail = recovered ? "已经回到同步前的状态，请在终端里处理" : "仓库可能停在 rebase 中途，请在终端里处理"
            return "rebase 没能走完（\(message)）。\(tail)"
        }
    }
}

/// `git rev-list --left-right --count <上游>...HEAD` 的输出：两个数，制表符分隔。
/// 左边是上游独有的（本地落后几个），右边是本地独有的（本地领先几个）。
public enum GitRevListCount {
    public static func parse(_ text: String) -> (behind: Int, ahead: Int)? {
        let numbers = text.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            .compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }
}
