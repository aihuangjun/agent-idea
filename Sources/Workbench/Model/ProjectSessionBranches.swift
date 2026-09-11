import Core
import Foundation

/// 新建分支对话框要的东西：从哪儿开出来。
struct NewBranchRequest: Identifiable, Equatable {
    let id = UUID()
    /// 起点（分支名或远程分支名）。默认是远程的默认分支（origin/master），IDEA 一样。
    let base: String
}

/// 当前分支没有上游时点了同步：给用户的选择。
struct UpstreamPrompt: Identifiable, Equatable {
    var id: String { branch }
    let branch: String
    /// 建议跟踪的远程分支：远程有同名分支就是它，否则远程的默认分支（origin/master）。
    let suggested: String?
    /// 推送时用的远程；没有配置远程仓库时 nil（那就什么都做不了，只能说明）。
    let remote: String?

    var title: String { "\(branch) 没有跟踪远程分支" }

    var message: String {
        guard let remote else {
            return "这个仓库没有配置远程仓库，没有地方可以同步。可以先在终端里 git remote add origin <地址>。"
        }
        var lines = ["同步要知道从哪个远程分支拉。"]
        if let suggested {
            if suggested == remote + "/" + branch {
                lines.append("· 跟踪 \(suggested)：远程已经有同名分支，只是本地没跟踪它。以后同步就从它拉。")
            } else {
                lines.append("· 跟踪 \(suggested)：以后同步就是 fetch 之后把 \(suggested) 上的新提交 rebase 进来；推送仍然推到远端的同名分支 \(remote)/\(branch)。")
            }
        }
        lines.append("· 推送并建立上游：把这个分支推到 \(remote)/\(branch)，以后同步拉的是它（拿不到 master 上的新提交）。")
        return lines.joined(separator: "\n")
    }
}

/// 分支：切换、新建（状态栏的分支弹窗，IDEA 的 Git Branches），以及当前分支没有上游时同步按钮给的选择。
extension ProjectSession {
    // MARK: - 同步按钮

    /// 当前分支还没有上游，但可以当场选一个：有仓库、状态读回来了、在一个有提交的分支上、没在同步 / 切分支。
    /// 这时同步按钮**不灰**，点了弹选项（1.2.0 前是灰着的，只有鼠标停上去才知道为什么）。
    var needsUpstreamChoice: Bool {
        let branch = gitSnapshot.branch
        return hasGit && hasLoadedGitStatus && !isSyncingRemote && !isSwitchingBranch
            && !branch.isUnborn && !branch.isDetached && branch.upstream == nil
    }

    /// 同步按钮能不能点：能直接同步，或者可以当场选上游。
    var canRequestSync: Bool { canSyncWithRemote || needsUpstreamChoice }

    /// 同步按钮 / ⌘T：有上游就同步；没有就问从哪儿同步（跟踪 origin/master，或推送并建立上游）。
    func requestSync() {
        if canSyncWithRemote {
            syncWithRemote()
            return
        }
        guard needsUpstreamChoice, let git, let repositoryRoot = project.repositoryRoot else { return }
        let branch = gitSnapshot.branch.name
        Task { [weak self] in
            do {
                let list = try await git.branches(repositoryRoot: repositoryRoot)
                guard let self else { return }
                self.branchList = list
                self.upstreamPrompt = UpstreamPrompt(branch: branch, suggested: list.suggestedUpstream(for: branch), remote: list.preferredRemote)
            } catch {
                // 读不出来不等于「没有远程」：别弹一句错话，照实说
                Log.warn("git", "读分支列表失败：\(error)")
                self?.showError("读不出分支和远程：\(error.userFacingDescription)")
            }
        }
    }

    /// 让当前分支跟踪 `upstream`，然后马上同步一次。
    func trackUpstream(_ upstream: String) {
        guard let git, let repositoryRoot = project.repositoryRoot, !isSyncingRemote, !isSwitchingBranch else { return }
        Task { [weak self] in
            do {
                try await git.setUpstream(upstream, repositoryRoot: repositoryRoot)
                Log.info("git", "当前分支改为跟踪 \(upstream)")
            } catch {
                self?.showError("跟踪 \(upstream) 失败：\(error.userFacingDescription)")
                return
            }
            guard let self else { return }
            self.refreshGit()
            // syncWithRemote 自己问 git 要上游，不等这次 status 回来
            self.syncWithRemote()
        }
    }

    /// 把当前分支推到 `remote` 上的同名分支并建立上游（`git push -u <remote> HEAD`，remote 就是弹窗里说的那个）。
    /// 结果报在状态栏（提交面板此刻多半不在界面上）。
    func pushSettingUpstream(to remote: String) {
        // 提交面板那边正在推的话别再并发推一次
        guard let git, let repositoryRoot = project.repositoryRoot, !isSyncingRemote, !isSwitchingBranch, commit?.isPushing != true else { return }
        let branch = gitSnapshot.branch.name
        isSyncingRemote = true
        Log.info("git", "推送并建立上游：\(branch)")
        Task { [weak self] in
            do {
                _ = try await git.push(repositoryRoot: repositoryRoot, hasUpstream: false, remote: remote)
                Log.info("git", "已推送 \(branch) 并建立上游")
                self?.notify("已推送 \(branch) 并建立上游，以后同步从远端的 \(branch) 拉")
            } catch {
                Log.warn("git", "推送并建立上游失败：\(error)")
                self?.showError("推送失败：\(error.userFacingDescription)")
            }
            guard let self else { return }
            self.isSyncingRemote = false
            self.refreshAll()
        }
    }

    // MARK: - 分支弹窗

    /// 打开分支弹窗（状态栏的分支名、Git → 分支…）。每次打开都重读一遍分支。
    func showBranches() {
        guard hasGit else { return }
        loadBranches()
        isBranchPopupShown = true
    }

    func loadBranches() {
        guard let git, let repositoryRoot = project.repositoryRoot else { return }
        Task { [weak self] in
            do {
                let list = try await git.branches(repositoryRoot: repositoryRoot)
                self?.branchList = list
            } catch {
                Log.warn("git", "读分支列表失败：\(error)")
            }
        }
    }

    /// 能不能切分支 / 建分支：有仓库、没在同步、没在切。
    var canSwitchBranch: Bool { hasGit && !isSyncingRemote && !isSwitchingBranch }

    /// 签出一个本地分支。
    func checkout(_ branch: GitBranchList.Local) {
        guard !branch.isCurrent else { return }
        switchBranch(to: branch.name) { git, root in try await git.switchBranch(to: branch.name, repositoryRoot: root) }
    }

    /// 签出一个远程分支（IDEA 的 Checkout）：本地已经有同名分支就切到它，没有就建一个跟踪它的本地分支。
    func checkout(remote remoteBranch: String) {
        guard let list = branchList else { return }
        let localName = list.localName(for: remoteBranch)
        if let existing = list.local(named: localName) {
            checkout(existing)
            return
        }
        switchBranch(to: localName) { git, root in
            try await git.createBranch(localName, from: remoteBranch, track: true, repositoryRoot: root)
        }
    }

    /// 新建分支的起点默认用哪个：远程的默认分支（origin/master），没有远程就是当前分支。
    var defaultNewBranchBase: String? { branchList?.defaultRemoteBranch ?? branchList?.current?.name ?? (gitSnapshot.branch.name.isEmpty ? nil : gitSnapshot.branch.name) }

    /// 新分支名能不能用（对话框边敲边查）。
    func newBranchProblem(_ name: String) -> GitBranchName.Problem? {
        GitBranchName.problem(name.trimmingCharacters(in: .whitespaces), existing: branchList?.local.map(\.name) ?? [])
    }

    /// 从 `base` 开一个新分支并切过去。起点是远程分支时新分支跟踪它（以后点同步就从它拉）。
    func createBranch(named rawName: String, from base: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = newBranchProblem(name) {
            showError("新建分支失败：\(problem.message)")
            return
        }
        let track = branchList?.remote.contains(base) ?? false
        switchBranch(to: name) { git, root in try await git.createBranch(name, from: base, track: track, repositoryRoot: root) }
    }

    /// 切分支的公共流程：先把编辑器里的写盘（草稿不在 git 眼里，切过去之后要么丢、要么被当成新分支上的改动），
    /// 切完整体刷新（目录树、开着的文件、git 状态、提交历史）。没提交的改动会被覆盖时 git 拒绝切，什么都不动，原话报出来。
    private func switchBranch(to target: String, _ operation: @escaping @Sendable (GitClient, URL) async throws -> Void) {
        guard canSwitchBranch, let git, let repositoryRoot = project.repositoryRoot else { return }
        isSwitchingBranch = true
        isBranchPopupShown = false
        saveAll { [weak self] in
            Task { [weak self] in
                do {
                    try await operation(git, repositoryRoot)
                    Log.info("git", "已切换到分支 \(target)")
                    self?.notify("已切换到 \(target)")
                } catch {
                    Log.warn("git", "切换到 \(target) 失败：\(error)")
                    self?.showError("切换到 \(target) 失败：\(error.userFacingDescription)")
                }
                guard let self else { return }
                self.isSwitchingBranch = false
                self.refreshAll()
                self.history?.reloadIfLoaded()
                self.loadBranches()
            }
        }
    }
}
