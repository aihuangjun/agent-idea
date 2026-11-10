import Foundation

/// 撤销提交（IDEA 的 Undo Commit）：`git reset --soft <提交前的 HEAD>`。改动不丢——工作区不动，
/// 提交里的内容回到暂存区，变更列表照常列出来；重做是 `reset --soft <这次提交>`。
///
/// 这里只有纯逻辑：一次提交记下什么（`GitCommitRecord`）、能不能撤 / 能不能重做（`GitCommitUndo.undoProblem` /
/// `redoProblem`）、撤 / 重做跑哪些 git 命令。真去问 git 的在 `GitClient`，流程在会话（`ProjectSessionUndo`）。
public struct GitCommitRecord: Equatable, Sendable {
    /// 这次提交（或 amend 之后）的完整 hash。
    public let head: String
    /// 提交之前的 HEAD：普通提交是它的父提交，amend 是被修改掉的那个旧提交（撤销 = 旧提交原样回来，
    /// amend 带进去的改动回到暂存区）。nil 是仓库的首个提交（撤销是删掉分支引用、保留索引）。
    public let previousHead: String?
    /// 提交时所在的分支；游离 HEAD 时为 nil。只比 hash 认不出「同一个提交上 `switch -c` 了一个新分支」。
    public let branch: String?
    /// 提交信息（撤销后填回输入框）。
    public let message: String
    public let isAmend: Bool
    /// 这一步是「提交并推送」：推送跑完之前不撤，推送成了就一直不撤。
    public let pushRequested: Bool
    /// 撤销成功之后索引的树（`git write-tree`）。重做前核对它没变：撤销之后用户动过暂存内容，就不该把 HEAD 搬回去。
    /// 不拿提交本身的树比：提交用的是 `--only`，提交时索引里可能还有终端里 add 过的别的东西，两棵树本来就不一样。
    public var indexTreeAfterUndo: String?

    public init(head: String, previousHead: String?, branch: String?, message: String, isAmend: Bool = false, pushRequested: Bool = false, indexTreeAfterUndo: String? = nil) {
        self.head = head
        self.previousHead = previousHead
        self.branch = branch
        self.message = message
        self.isAmend = isAmend
        self.pushRequested = pushRequested
        self.indexTreeAfterUndo = indexTreeAfterUndo
    }

    public var shortHash: String { String(head.prefix(7)) }

    /// 提交信息的第一行（状态栏提示用）。
    public var subject: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// 仓库正停在一次没走完的操作中途。这时挪 HEAD 会把那次操作的状态搅乱（rebase 的待办、merge 的另一头都还指着旧 HEAD）。
public enum GitOperationInProgress: String, Equatable, Sendable, CaseIterable {
    case rebase
    case merge
    case cherryPick
    case revert

    /// `git rev-parse --git-path <名>` 问的那几个标记（文件或目录），有一个在就算这种操作在进行。
    public var markers: [String] {
        switch self {
        case .rebase: return ["rebase-merge", "rebase-apply"]
        case .merge: return ["MERGE_HEAD"]
        case .cherryPick: return ["CHERRY_PICK_HEAD"]
        case .revert: return ["REVERT_HEAD"]
        }
    }

    public var label: String {
        switch self {
        case .rebase: return "rebase"
        case .merge: return "合并"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }
}

/// 不能撤 / 不能重做的原因。`message` 是给人看的那句。
public enum GitCommitUndoProblem: Equatable, Sendable {
    /// 正在提交 / 推送 / 同步 / 切分支：等它做完。
    case busy
    /// 「提交并推送」的推送还在跑。
    case pushing
    /// 已经在远程分支上了（推送过）。撤销要强制推送才能让远端跟上，我们不替用户做。
    case pushed
    /// HEAD 已经不是这次提交了：之后又有提交、切了分支、rebase 过。
    case headMoved
    /// 换了分支（哪怕指着同一个提交）。
    case branchChanged
    case operationInProgress(GitOperationInProgress)
    /// 重做：撤销之后暂存区被改过（或者有冲突，`write-tree` 写不出来）。
    case indexChanged
    /// 历史里的这个提交没有父提交（仓库的第一个提交）。
    case rootCommit
    /// 合并提交：soft reset 回第一个父提交会把另一头的改动全堆进暂存区，不是用户想要的「撤销」。
    case mergeCommit
    /// 不在任何分支上（游离 HEAD）。
    case detached

    public var message: String {
        switch self {
        case .busy: return "有别的 git 操作正在进行，等它做完再试"
        case .pushing: return "正在推送，等推送结束再试"
        case .pushed: return "已推送到远程，撤销需要强制推送，未执行"
        case .headMoved: return "HEAD 已经不是这次提交了（之后又有提交、切过分支或 rebase 过）"
        case .branchChanged: return "已经切到别的分支了"
        case .operationInProgress(let operation): return "仓库正停在一次\(operation.label)中途，先在终端里完成或放弃它"
        case .indexChanged: return "撤销之后暂存区又被改过，重做会把这些改动混进那次提交"
        case .rootCommit: return "这是仓库的第一个提交，没有可以退回的父提交"
        case .mergeCommit: return "合并提交不能这样撤销"
        case .detached: return "当前不在分支上（游离 HEAD）"
        }
    }
}

/// 撤销 / 重做一次提交前的核对与要跑的命令。
public enum GitCommitUndo {
    /// 撤销前此刻仓库的样子（会话问 git 得来的）。
    public struct State: Equatable, Sendable {
        /// 此刻 HEAD 的完整 hash；没有提交时为 nil。
        public var head: String?
        /// 此刻所在的分支；游离为 nil。
        public var branch: String?
        public var operation: GitOperationInProgress?
        /// 这次提交在不在某个远程跟踪分支上（`branch -r --contains`）。
        public var isOnRemote: Bool
        /// 本会话推送成功过它（推送到一个不更新远程跟踪分支的地方时，上一条查不出来）。
        public var wasPushed: Bool
        public var isPushing: Bool
        public var isBusy: Bool
        /// 此刻索引的树（重做前查）；写不出来（有未合并项）为 nil。
        public var indexTree: String?

        public init(head: String?, branch: String?, operation: GitOperationInProgress? = nil, isOnRemote: Bool = false, wasPushed: Bool = false,
                    isPushing: Bool = false, isBusy: Bool = false, indexTree: String? = nil) {
            self.head = head
            self.branch = branch
            self.operation = operation
            self.isOnRemote = isOnRemote
            self.wasPushed = wasPushed
            self.isPushing = isPushing
            self.isBusy = isBusy
            self.indexTree = indexTree
        }
    }

    /// 能不能撤：没在忙、HEAD 还是这次提交、还在同一个分支上、没有半截的操作、没推送过。
    public static func undoProblem(_ record: GitCommitRecord, state: State) -> GitCommitUndoProblem? {
        if state.isBusy { return .busy }
        if record.pushRequested, state.isPushing { return .pushing }
        guard state.head == record.head else { return .headMoved }
        guard state.branch == record.branch else { return .branchChanged }
        if let operation = state.operation { return .operationInProgress(operation) }
        if state.isOnRemote || state.wasPushed { return .pushed }
        return nil
    }

    /// 能不能重做：HEAD 还在撤销之后的位置、同一个分支、暂存区与撤销刚做完时一样。
    public static func redoProblem(_ record: GitCommitRecord, state: State) -> GitCommitUndoProblem? {
        if state.isBusy { return .busy }
        guard state.head == record.previousHead else { return .headMoved }
        guard state.branch == record.branch else { return .branchChanged }
        if let operation = state.operation { return .operationInProgress(operation) }
        guard let tree = state.indexTree, tree == record.indexTreeAfterUndo else { return .indexChanged }
        return nil
    }

    /// 撤销的 git 参数。首个提交没有可退回的提交：删掉分支引用（`update-ref -d HEAD <它>` 顺着 HEAD 找到分支，
    /// 带上旧值是原子的「还是它才删」），索引与工作区都不动，又回到「还没有提交」。
    public static func undoArguments(_ record: GitCommitRecord) -> [String] {
        if let previous = record.previousHead {
            return ["reset", "--soft", previous]
        }
        return ["update-ref", "-m", "agentidea: undo commit", "-d", "HEAD", record.head]
    }

    /// 重做的 git 参数。首个提交那种：旧值给空串 = 「HEAD 指的分支此刻必须不存在」，又是原子的。
    public static func redoArguments(_ record: GitCommitRecord) -> [String] {
        if record.previousHead != nil {
            return ["reset", "--soft", record.head]
        }
        return ["update-ref", "-m", "agentidea: redo commit", "HEAD", record.head, ""]
    }

    /// 提交历史右键「撤销提交」（不是本会话提交的也行）：只给当前分支上的 HEAD，而且是有且只有一个父提交的那种。
    /// 返回 nil 是能撤（是否推送过由点击时再查）。
    public static func historyProblem(for commit: GitCommit, head: String, branch: GitBranch) -> GitCommitUndoProblem? {
        guard !head.isEmpty, commit.hash == head else { return .headMoved }
        if branch.isDetached { return .detached }
        if commit.parents.isEmpty { return .rootCommit }
        if commit.parents.count > 1 { return .mergeCommit }
        return nil
    }

    /// 历史里那个提交对应的记录（previousHead = 第一个父提交）。
    public static func record(for commit: GitCommit, branch: String?) -> GitCommitRecord {
        let message = commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body
        return GitCommitRecord(head: commit.hash, previousHead: commit.parents.first, branch: branch, message: message)
    }
}
