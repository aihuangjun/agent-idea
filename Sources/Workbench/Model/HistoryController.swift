import Core
import Foundation

/// 提交历史工具窗口的状态：分页拉 `git log`，选中一条时列出它改了哪些文件。
///
/// 只认识 git 与仓库根；打开 diff 标签是会话的事，视图直接调会话。
@MainActor
final class HistoryController: ObservableObject {
    nonisolated static let pageSize = 100

    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var selectedCommitID: String?
    /// 每次提交改的文件，按需拉、拉过就留着（提交是不可变的）。拉失败的不进这里，重新选中会再试。
    @Published private(set) var filesByCommit: [String: [GitChange]] = [:]
    /// 拉文件列表失败的原因，按提交。
    @Published private(set) var filesError: [String: String] = [:]
    /// 当前 HEAD，由会话在每次 git 状态刷新后写入；与 `loadedHead` 不同才需要重拉。
    var currentHead = ""

    private let git: GitClient
    private let repositoryRoot: URL
    private var hasLoaded = false
    private var loadedHead = ""
    private var loadTask: Task<Void, Never>?
    private var fetchingFiles: Set<String> = []

    init(git: GitClient, repositoryRoot: URL) {
        self.git = git
        self.repositoryRoot = repositoryRoot
    }

    var selectedCommit: GitCommit? {
        guard let selectedCommitID else { return nil }
        return commits.first { $0.id == selectedCommitID }
    }

    /// 工具窗口第一次显示时拉第一页；之后由 HEAD 变化触发 `refresh`。
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    /// 重拉第一页。已选中的提交还在的话保持选中。
    func refresh() {
        hasLoaded = true
        load(skip: 0)
    }

    /// HEAD 变了：拉过的话重拉，没打开过历史就等打开时再说。已经是这个 HEAD 的不重复拉。
    func refreshIfLoaded() {
        if hasLoaded, loadedHead != currentHead { refresh() }
    }

    /// 项目关掉：正在跑的都停掉。
    func cancel() {
        loadTask?.cancel()
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        load(skip: commits.count)
    }

    private func load(skip: Int) {
        loadTask?.cancel()
        isLoading = true
        loadedHead = currentHead
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await git.log(repositoryRoot: repositoryRoot, limit: Self.pageSize, skip: skip)
                guard !Task.isCancelled else { return }
                commits = skip == 0 ? page : commits + page
                hasMore = page.count == Self.pageSize
                error = nil
                if let selectedCommitID, !commits.contains(where: { $0.id == selectedCommitID }) { self.selectedCommitID = nil }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.userFacingDescription
                Log.warn("git", "log 失败：\(error)")
            }
            isLoading = false
        }
    }

    // MARK: - 选中与文件列表

    func select(_ commit: GitCommit?) {
        selectedCommitID = commit?.id
        guard let commit, filesByCommit[commit.id] == nil, !fetchingFiles.contains(commit.id) else { return }
        fetchingFiles.insert(commit.id)
        filesError[commit.id] = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                filesByCommit[commit.id] = try await git.changedFiles(in: commit, repositoryRoot: repositoryRoot)
            } catch {
                filesError[commit.id] = error.userFacingDescription
                Log.warn("git", "取提交 \(commit.shortHash) 的文件列表失败：\(error)")
            }
            fetchingFiles.remove(commit.id)
        }
    }

    func moveSelection(by offset: Int) {
        guard !commits.isEmpty else { return }
        let current = commits.firstIndex { $0.id == selectedCommitID } ?? (offset > 0 ? -1 : commits.count)
        select(commits[min(commits.count - 1, max(0, current + offset))])
    }
}
