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
    /// `--autostash` 收起来的改动放回工作区时冲突了。
    ///
    /// rebase 本身成功了（git 把这算警告，退出码仍是 0），但用户没提交的改动只剩在 stash 里、
    /// 工作区带着冲突标记——不特意说一声的话，界面会显示「同步成功」，用户的改动就这么不见了。
    public let autostashConflicted: Bool

    public init(upstream: String, pulled: Int, replayed: Int, autostashConflicted: Bool = false) {
        self.upstream = upstream
        self.pulled = pulled
        self.replayed = replayed
        self.autostashConflicted = autostashConflicted
    }

    /// git 有没有在说「autostash 放不回去」。环境里固定了 `LC_ALL=C`，这句话是稳定的英文。
    public static func mentionsAutostashConflict(_ output: String) -> Bool {
        output.contains("Applying autostash resulted in conflicts")
    }

    /// 上游没有新东西时不跑 rebase：本地什么都没动。
    public var didRebase: Bool { pulled > 0 }

    /// 给用户看的一句话。
    public var summary: String {
        if autostashConflicted {
            return "已从 \(upstream) 拉取 \(pulled) 个提交，但你没提交的改动放回工作区时冲突了："
                + "改动还留在 git stash 里（git stash list），工作区带着冲突标记，请在终端里处理"
        }
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
    /// 仓库正停在一次 rebase 中途（用户自己在终端里开的）。
    case rebaseInProgress
    /// `rev-list --left-right --count` 的输出看不懂，不知道落后 / 领先几个提交。
    case unreadableDivergence(String)
    /// rebase 没走完（多半是冲突）。`recovered` 表示已经 `rebase --abort` 回到同步前的样子。
    case rebaseFailed(message: String, recovered: Bool)
    /// `git fetch` 连续好几秒没有任何动静，被停掉了（仓库没动：拉下来的东西要到最后才落到引用上）。
    case fetchStalled(seconds: Int)
    /// `git push` 连续好几秒没有任何动静，被停掉了。
    case pushStalled(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .unborn:
            return "仓库还没有任何提交，没有可同步的分支"
        case .noUpstream(let branch):
            return "\(branch) 没有跟踪远程分支，先 git push -u 建立上游再同步"
        case .rebaseInProgress:
            return "仓库正停在一次 rebase 中途，先在终端里 git rebase --continue 或 --abort，再来同步"
        case .unreadableDivergence(let output):
            return "看不懂 git 报的落后 / 领先提交数（\(output)），没敢动仓库"
        case .rebaseFailed(let message, let recovered):
            let tail = recovered ? "已经回到同步前的状态，请在终端里处理" : "仓库可能停在 rebase 中途，请在终端里处理"
            return "rebase 没能走完（\(message)）。\(tail)"
        case .fetchStalled(let seconds):
            return "git fetch 连续 \(seconds) 秒没有任何动静，已经停掉了，仓库没动。多半是网络不通、VPN 没连，或者 ssh 连接卡住了；可以在终端里跑 git fetch 看看卡在哪"
        case .pushStalled(let seconds):
            return "git push 连续 \(seconds) 秒没有任何动静，已经停掉了。多半是网络不通、VPN 没连，或者 ssh 连接卡住了；远端有没有收到，可以在终端里 git fetch 之后看 git status"
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

/// 带 `--progress` 跑的 git 命令，stderr 里夹着一大串进度行（`Receiving objects:  45% (450/1000)`，靠 `\r` 原地刷新）。
/// 出错时给人看的只该是真正的错误那几行。
public enum GitProgress {
    public static func removingProgress(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isProgress($0) }
            .joined(separator: "\n")
    }

    /// 「Enumerating objects: 5, done.」「Receiving objects:  45% (450/1000)」「remote: Total 3 (delta 0), reused 0」这种，
    /// 以及推送时那句「Delta compression using up to 12 threads」（没有冒号，1.2.1 发布前的 review 抓的：它曾被当成推送结果显示）。
    /// 「fatal: …」「ssh: connect to host … port 22: …」冒号后面不是数字，不算。
    static func isProgress(_ line: String) -> Bool {
        let body = line.hasPrefix("remote: ") ? String(line.dropFirst("remote: ".count)) : line
        if body.hasPrefix("Total ") || body.hasPrefix("Delta compression using up to ") { return true }
        return body.range(of: #"^[A-Z][A-Za-z ]*: +[0-9]+(%|,| |$)"#, options: .regularExpression) != nil
    }
}
