import Core
import Foundation

/// 提交面板的状态与 git 写操作：勾选、提交、推送、回滚、删除未跟踪文件。
///
/// 只认识 git 与仓库根，不认识标签页和目录树；做完一件事通过 `onRepositoryChanged` 通知会话去刷新。
@MainActor
final class CommitController: ObservableObject {
    @Published var message = ""
    /// 不勾选（不提交）的路径。默认全选，新出现的变更自动算勾上。
    @Published private(set) var excludedPaths: Set<String> = []
    @Published private(set) var isCommitting = false
    @Published private(set) var isPushing = false
    /// 最近一次操作的结果或错误，显示在提交面板底部。
    @Published private(set) var status: OperationStatus?

    private let git: GitClient
    private let repositoryRoot: URL
    private var snapshot: GitSnapshot = .empty
    /// 仓库被改了（提交、回滚、删文件之后）。参数是受影响的变更，会话据此关掉对应的 diff 标签。
    var onRepositoryChanged: (@MainActor ([GitChange]) -> Void)?

    init(git: GitClient, repositoryRoot: URL) {
        self.git = git
        self.repositoryRoot = repositoryRoot
    }

    /// 每次 git 状态刷新后调：把已经不存在的变更从「不勾选」集合里清掉。
    func update(snapshot: GitSnapshot) {
        self.snapshot = snapshot
        excludedPaths = excludedPaths.intersection(snapshot.changes.map(\.path))
    }

    func dismissStatus() { status = nil }

    // MARK: - 勾选

    func isIncluded(_ change: GitChange) -> Bool { !excludedPaths.contains(change.path) }

    func setIncluded(_ included: Bool, for change: GitChange) {
        if included { excludedPaths.remove(change.path) } else { excludedPaths.insert(change.path) }
    }

    var includedChanges: [GitChange] {
        snapshot.changes.filter { !excludedPaths.contains($0.path) }
    }

    // MARK: - 提交与推送

    var canCommit: Bool {
        !isCommitting && !isPushing && !includedChanges.isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPush: Bool { !isCommitting && !isPushing && !snapshot.branch.isUnborn }

    /// 提交勾选的变更；`push` 为 true 时接着推送。
    func commit(push: Bool) {
        guard canCommit else { return }
        let changes = includedChanges
        let paths = changes.map(\.path) + changes.compactMap(\.originalPath)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        isCommitting = true
        status = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await git.commit(paths: paths, message: trimmed, repositoryRoot: repositoryRoot)
                message = ""
                isCommitting = false
                status = .success("已提交 \(result.shortHash)（\(result.fileCount) 个文件）")
                Log.info("git", "提交 \(result.shortHash)：\(result.fileCount) 个文件")
                onRepositoryChanged?(changes)
                if push { pushCurrentBranch() }
            } catch {
                isCommitting = false
                status = .failure("提交失败：\(error.userFacingDescription)")
                Log.warn("git", "提交失败：\(error)")
                onRepositoryChanged?([])
            }
        }
    }

    func pushCurrentBranch() {
        guard canPush else { return }
        let hasUpstream = snapshot.branch.upstream != nil
        isPushing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await git.push(repositoryRoot: repositoryRoot, hasUpstream: hasUpstream)
                isPushing = false
                let summary = output.split(separator: "\n").last.map(String.init) ?? ""
                status = .success(summary.isEmpty ? "已推送" : "已推送：\(summary)")
                Log.info("git", "推送完成：\(output)")
            } catch {
                isPushing = false
                status = .failure("推送失败：\(error.userFacingDescription)")
                Log.warn("git", "推送失败：\(error)")
            }
            onRepositoryChanged?([])
        }
    }

    // MARK: - 回滚与删除

    /// 回滚一条变更到 HEAD。修改/删除/重命名/冲突 → restore；新增（已在索引）→ 连文件一起删。
    /// 未跟踪文件不在 git 里、没有可回滚的目标，走 `delete`。
    /// 做完（成功与否）调 `completion`：会话据此记撤销栈。未跟踪文件的回滚其实是删除，撤销也按删除记（`completion` 不会被调）。
    func rollback(_ change: GitChange, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard change.kind != .untracked else {
            delete(change)
            return
        }
        rollback([change]) { completion(!$0.isEmpty) }
    }

    /// 一次回滚好几条（变更列表多选）。未跟踪的跳过：它们不在 git 里，「回滚」对它们就是删除，要删走 `delete`。
    /// 能一起跑的合成一两条 git 命令（几十个文件不用起几十次 git）；一起跑失败了再逐条跑，挑出到底是哪几条不行，
    /// 别的照样回滚掉。做完调 `completion`，参数是真回滚成了的那些（会话据此记一步撤销），会话只刷新一次。
    func rollback(_ changes: [GitChange], completion: @escaping @MainActor ([GitChange]) -> Void) {
        let targets = changes.filter { $0.kind != .untracked }
        guard !targets.isEmpty else {
            completion([])
            return
        }
        Task { [weak self] in
            guard let self else {
                completion([])
                return
            }
            var succeeded: [GitChange] = []
            var failures: [(GitChange, Error)] = []
            do {
                try await revertToHead(targets)
                succeeded = targets
            } catch let error where targets.count > 1 {
                Log.info("git", "一起回滚 \(targets.count) 个失败，改为逐个回滚：\(error)")
                for change in targets {
                    do {
                        try await revertToHead([change])
                        succeeded.append(change)
                    } catch {
                        failures.append((change, error))
                    }
                }
            } catch {
                failures.append((targets[0], error))
            }
            for change in succeeded { Log.info("git", "已回滚 \(change.path)") }
            for (change, error) in failures { Log.warn("git", "回滚 \(change.path) 失败：\(error)") }
            if let (change, error) = failures.first {
                status = .failure(targets.count == 1
                    ? "回滚失败：\(error.userFacingDescription)"
                    : "有 \(failures.count) 个没能回滚，比如 \(change.fileName)：\(error.userFacingDescription)")
            }
            onRepositoryChanged?(targets)
            completion(succeeded)
        }
    }

    /// 修改 / 删除 / 重命名 / 冲突 → `restore`（重命名连原路径一起）；新增（已在索引、HEAD 里没有）→ 连文件一起 `rm`。
    private func revertToHead(_ changes: [GitChange]) async throws {
        let restored = changes.filter { $0.kind != .added }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        let added = changes.filter { $0.kind == .added }.map(\.path)
        if !restored.isEmpty { try await git.restoreToHead(paths: restored, repositoryRoot: repositoryRoot) }
        if !added.isEmpty { try await git.removeAdded(paths: added, repositoryRoot: repositoryRoot) }
    }

    /// 撤销「回滚」的后半步：把写回来的文件重新记进索引（新增 / 重命名的状态才回得来）。
    func stage(paths: [String]) async throws {
        try await git.stage(paths: paths, repositoryRoot: repositoryRoot)
    }

    // MARK: - 添加到 git（目录树右键）

    /// 这些路径下 git 还不认识的文件，逐个列出来（`ignored` 为 true 时列被忽略的那些）。
    func untrackedFiles(under paths: [String], ignored: Bool) async throws -> [String] {
        try await git.untrackedFiles(under: paths, ignored: ignored, repositoryRoot: repositoryRoot)
    }

    /// 纳入版本管理。被忽略的路径要 `force`。
    func add(paths: [String], force: Bool) async throws {
        try await git.add(paths: paths, force: force, repositoryRoot: repositoryRoot)
    }

    /// 撤销「添加到 git」：从索引里撤下来，磁盘上的文件不动。
    func unstage(paths: [String]) async throws {
        try await git.unstage(paths: paths, repositoryRoot: repositoryRoot)
    }

    /// 能不能删：磁盘上还有文件才行（「已删除」的变更没有东西可删）。
    func canDelete(_ change: GitChange) -> Bool { change.kind != .deleted }

    /// 删除一条变更对应的文件：进废纸篓，不是 rm——IDEA 的删除能从本地历史找回来，这里用废纸篓兜底。
    /// 已跟踪的文件删掉之后 git 会把它显示成「已删除」，要不要提交这次删除由用户决定；未跟踪的删掉就没了。
    /// 返回文件在废纸篓里的位置（撤销删除从那里搬回来），删不成返回 nil。
    @discardableResult
    func delete(_ change: GitChange) -> URL? {
        delete([change]).first?.trashed
    }

    /// 删好几条（变更列表多选）：各自进废纸篓，删不成的跳过、报一句；会话只刷新一次。「已删除」的变更没有东西可删，跳过。
    /// 返回删成了的那些和它们在废纸篓里的位置（撤销从那里搬回来）。
    @discardableResult
    func delete(_ changes: [GitChange]) -> [(change: GitChange, trashed: URL)] {
        let targets = changes.filter(canDelete)
        guard !targets.isEmpty else { return [] }
        var deleted: [(change: GitChange, trashed: URL)] = []
        var failures: [(GitChange, Error)] = []
        for change in targets {
            do {
                deleted.append((change, try Trash.move(repositoryRoot.appendingPathComponent(change.path))))
                Log.info("git", "已删除 \(change.path)")
            } catch {
                failures.append((change, error))
                Log.warn("git", "删除 \(change.path) 失败：\(error)")
            }
        }
        if let (change, error) = failures.first {
            status = .failure(targets.count == 1
                ? "删除失败：\(error.userFacingDescription)"
                : "有 \(failures.count) 个没能删除，比如 \(change.fileName)：\(error.userFacingDescription)")
        }
        onRepositoryChanged?(targets)
        return deleted
    }
}

