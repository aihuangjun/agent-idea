import Core
import Foundation

/// 历史详情区在看什么：一次提交，或一段提交合起来（多选、与分支比较）。
enum HistoryDetail: Equatable {
    case commit(GitCommit)
    case range(GitCommitRange)

    /// 文件列表、统计、错误在 `HistoryController` 里按它存：提交是 hash，区间是 `base..target`，两者不会撞。
    var key: String {
        switch self {
        case .commit(let commit): return commit.id
        case .range(let range): return range.id
        }
    }

    var base: String {
        switch self {
        case .commit(let commit): return commit.diffBase
        case .range(let range): return range.base
        }
    }

    var target: String {
        switch self {
        case .commit(let commit): return commit.hash
        case .range(let range): return range.target
        }
    }

    var isRange: Bool {
        if case .range = self { return true }
        return false
    }

    /// 状态行、日志里怎么称呼它。
    var label: String {
        switch self {
        case .commit(let commit): return commit.shortHash
        case .range(let range): return range.badge
        }
    }
}

/// 提交历史工具窗口的状态：分页拉 `git log`，选中一条时列出它改了哪些文件；多选时列出这一段合起来改了哪些文件。
/// 「与分支比较」时进入比较模式：列表只列 `merge-base..HEAD` 的提交，什么都不选时详情是整段比较。
///
/// 只认识 git 与仓库根；打开 diff 标签是会话的事，视图直接调会话。回滚了历史里的变更会通过 `onRepositoryChanged` 通知会话刷新。
@MainActor
final class HistoryController: ObservableObject {
    nonisolated static let pageSize = 100

    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// 选中的提交（键是 hash）。单击选一个，⌘点击加减，⇧点击连选——与变更列表同一套。
    @Published private(set) var selection = TreeSelection()
    /// 比较模式在跟哪个分支比；nil 是普通的历史列表。进入时就有值（解析区间期间标题条已经要显示「与 X 比较」）。
    @Published private(set) var comparedBranch: String?
    /// 比较模式解析出来的区间（merge-base → HEAD，都是 hash）。
    @Published private(set) var comparison: GitCommitRange?
    /// 每次提交 / 每段区间改的文件，按 `HistoryDetail.key` 存；按需拉、拉过就留着（两头都是 hash，内容不会变）。拉失败的不进这里，重新选中会再试。
    @Published private(set) var files: [String: [GitChange]] = [:]
    /// 拉文件列表失败的原因，按 `HistoryDetail.key`。
    @Published private(set) var filesError: [String: String] = [:]
    @Published private(set) var statistics: [String: [String: DiffLineCounts]] = [:]
    /// 当前 HEAD，由会话在每次 git 状态刷新后写入；与 `loadedHead` 不同才需要重拉。
    var currentHead = ""
    /// 最近一次回滚的结果，显示在文件列表下面。
    @Published private(set) var status: OperationStatus?
    @Published private(set) var isReverting = false
    /// 工作区被改了（回滚之后）：会话据此刷新树、git 状态与开着的文件。
    var onRepositoryChanged: (@MainActor () -> Void)?

    private let git: GitClient
    private let repositoryRoot: URL
    private var hasLoaded = false
    private var loadedHead = ""
    private var loadTask: Task<Void, Never>?
    private var compareTask: Task<Void, Never>?
    private var fetchingFiles: Set<String> = []

    init(git: GitClient, repositoryRoot: URL) {
        self.git = git
        self.repositoryRoot = repositoryRoot
    }

    /// 只选中了一个提交时是它；多选、没选都是 nil。
    var selectedCommitID: String? {
        selection.count == 1 ? selection.paths.first : nil
    }

    var selectedCommit: GitCommit? {
        guard let selectedCommitID else { return nil }
        return commits.first { $0.id == selectedCommitID }
    }

    /// 详情区看什么：多选是那一段；单选是那次提交；比较模式下什么都没选是整段比较。
    var detail: HistoryDetail? {
        if selection.count > 1 {
            return GitCommitRange.selection(selection.paths, in: commits).map(HistoryDetail.range)
        }
        if let commit = selectedCommit { return .commit(commit) }
        if selection.isEmpty, let comparison { return .range(comparison) }
        return nil
    }

    /// 工具窗口第一次显示时拉第一页；之后由 HEAD 变化触发 `refresh`。
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    /// 重拉第一页。已选中的提交还在的话保持选中。比较模式下按分支名重新算区间（HEAD、那个分支都可能动过）。
    func refresh() {
        hasLoaded = true
        if let comparedBranch {
            compare(withBranch: comparedBranch)
        } else {
            load(skip: 0)
        }
    }

    /// HEAD 变了：拉过的话重拉，没打开过历史就等打开时再说。已经是这个 HEAD 的不重复拉。
    func refreshIfLoaded() {
        if hasLoaded, loadedHead != currentHead { refresh() }
    }

    /// 用户明确要求刷新（与远程同步之后）：打开过历史就重拉，HEAD 没变也拉——远程可能改写过历史。
    /// 没打开过的不主动拉，跟 `refreshIfLoaded` 一样等打开时再说。
    func reloadIfLoaded() {
        if hasLoaded { refresh() }
    }

    /// 项目关掉：正在跑的都停掉。
    func cancel() {
        loadTask?.cancel()
        compareTask?.cancel()
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        load(skip: commits.count)
    }

    private func load(skip: Int) {
        loadTask?.cancel()
        isLoading = true
        loadedHead = currentHead
        let range = comparison
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await git.log(repositoryRoot: repositoryRoot, limit: Self.pageSize, skip: skip, range: range)
                guard !Task.isCancelled else { return }
                commits = skip == 0 ? page : commits + page
                hasMore = page.count == Self.pageSize
                error = nil
                let order = commits.map(\.id)
                selection.retain(Set(order), order: order)
                fetchFilesForDetail()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.userFacingDescription
                Log.warn("git", "log 失败：\(error)")
            }
            isLoading = false
        }
    }

    // MARK: - 比较模式

    /// 与分支比较（IDEA 的 Compare with Current）：当前分支比它多改了什么，即 `merge-base(分支, HEAD)` → HEAD。
    /// 两头都解析成 hash；提交列表与文件 diff 用同一个 base，「N 个提交」与文件列表才对得上。
    func compare(withBranch branch: String) {
        // 先占住：从分支弹窗进来时工具窗口可能还没建出来，它出现时的 loadIfNeeded 不能再拉一遍普通 log 把比较盖掉
        hasLoaded = true
        let isNewComparison = comparedBranch != branch
        compareTask?.cancel()
        loadTask?.cancel()
        comparedBranch = branch
        if isNewComparison {
            comparison = nil
            commits = []
            hasMore = false
            selection = TreeSelection()
        }
        error = nil
        isLoading = true
        loadedHead = currentHead
        compareTask = Task { [weak self] in
            guard let self else { return }
            do {
                let range = try await git.compareRange(withBranch: branch, repositoryRoot: repositoryRoot)
                guard !Task.isCancelled, comparedBranch == branch else { return }
                comparison = range
                Log.info("git", "与 \(branch) 比较：\(range.id)，\(range.commitCount) 个提交")
                load(skip: 0)
            } catch {
                guard !Task.isCancelled, comparedBranch == branch else { return }
                comparison = nil
                commits = []
                hasMore = false
                self.error = error.userFacingDescription
                isLoading = false
                Log.warn("git", "与 \(branch) 比较失败：\(error)")
            }
        }
    }

    /// 退出比较模式，回到普通的历史列表。
    func exitComparison() {
        guard comparedBranch != nil else { return }
        compareTask?.cancel()
        comparedBranch = nil
        comparison = nil
        commits = []
        hasMore = false
        selection = TreeSelection()
        error = nil
        load(skip: 0)
    }

    // MARK: - 选中与文件列表

    /// 只选这一个（nil 清空；比较模式下清空就是看整段比较）。
    func select(_ commit: GitCommit?) {
        selection.select(commit?.id)
        // 按传进来的提交拉，不经 detail（它要在已加载的列表里找得到这个提交）
        fetchFiles(for: commit.map(HistoryDetail.commit) ?? detail)
    }

    /// ⌘点击：加进 / 移出多选。
    func toggleSelection(_ commit: GitCommit) {
        selection.toggle(commit.id, order: commits.map(\.id))
        fetchFilesForDetail()
    }

    /// ⇧点击：从锚点连选到这一个。
    func extendSelection(to commit: GitCommit) {
        selection.extend(to: commit.id, order: commits.map(\.id))
        fetchFilesForDetail()
    }

    /// 右键「比较从这里到 HEAD」：从它一直选到列表最上面（HEAD），详情就是这一段合起来的变更。
    func selectThroughHead(from commit: GitCommit) {
        guard let head = commits.first, commits.contains(commit) else { return }
        // 锚点留在点的那一个上：之后 ⇧点击从它接着连选
        selection.select(commit.id)
        selection.extend(to: head.id, order: commits.map(\.id))
        fetchFilesForDetail()
    }

    func moveSelection(by offset: Int) {
        guard !commits.isEmpty else { return }
        let current = commits.firstIndex { $0.id == selection.anchor } ?? (offset > 0 ? -1 : commits.count)
        select(commits[min(commits.count - 1, max(0, current + offset))])
    }

    /// 详情要的文件列表与增删行数，没拉过就拉。
    private func fetchFilesForDetail() {
        fetchFiles(for: detail)
    }

    private func fetchFiles(for detail: HistoryDetail?) {
        guard let detail, files[detail.key] == nil, !fetchingFiles.contains(detail.key) else { return }
        let key = detail.key, base = detail.base, target = detail.target, label = detail.label
        fetchingFiles.insert(key)
        filesError[key] = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                files[key] = try await git.changedFiles(base: base, target: target, repositoryRoot: repositoryRoot)
                statistics[key] = try? await git.diffStatistics(base: base, target: target, repositoryRoot: repositoryRoot)
            } catch {
                filesError[key] = error.userFacingDescription
                Log.warn("git", "取 \(label) 的文件列表失败：\(error)")
            }
            fetchingFiles.remove(key)
        }
    }

    // MARK: - 回滚

    func dismissStatus() { status = nil }

    /// 把某次提交里一个文件的变更反向打回工作区（IDEA 的 Revert Selected Changes）。不产生提交。
    func revert(_ change: GitChange, in commit: GitCommit) {
        revert(change, in: .commit(commit))
    }

    /// 同上；区间就是把这一段合起来对这个文件的改动反向打回去。
    func revert(_ change: GitChange, in detail: HistoryDetail) {
        guard !isReverting else { return }
        isReverting = true
        status = nil
        Task { [weak self] in
            guard let self else { return }
            defer { isReverting = false }
            do {
                try await git.revert(change: change, base: detail.base, target: detail.target, repositoryRoot: repositoryRoot)
                status = .success("已回滚 \(change.fileName)（\(detail.label)），改动在工作区里，未提交")
                Log.info("git", "回滚 \(detail.label) 里的 \(change.path)")
            } catch {
                status = .failure("回滚失败：\(error.userFacingDescription)")
                Log.warn("git", "回滚 \(detail.label) 里的 \(change.path) 失败：\(error)")
            }
            onRepositoryChanged?()
        }
    }
}
