import Core
import Foundation

/// 文件操作的撤销 / 重做（IDEA 的 Undo / Redo 里编辑之外的那部分）：重命名、移动、删除、回滚、添加到 git。
/// 栈是 `UndoHistory`（Core，纯逻辑）；这里管每一种操作怎么撤、怎么重做，以及撤不成时怎么说。
/// 撤销前先核对磁盘：这中间文件被删了、改名了、原位置被别的东西占了，就报错并把这一步丢掉（留着下次还是撤不成）。
extension ProjectSession {
    var canUndo: Bool { undoHistory.canUndo }
    var canRedo: Bool { undoHistory.canRedo }
    /// 菜单项标题：「撤销重命名 a.txt」；没有可撤的就是「撤销」。
    var undoTitle: String { undoHistory.nextUndo.map { "撤销" + $0.title } ?? "撤销" }
    var redoTitle: String { undoHistory.nextRedo.map { "重做" + $0.title } ?? "重做" }
    var nextUndoIsCommit: Bool { if case .commit? = undoHistory.nextUndo?.kind { return true } else { return false } }
    var nextRedoIsCommit: Bool { if case .commit? = undoHistory.nextRedo?.kind { return true } else { return false } }

    @discardableResult
    func recordUndo(_ title: String, _ kind: UndoableOperation.Kind) -> UndoableOperation {
        let operation = UndoableOperation(title: title, kind: kind)
        undoHistory.record(operation)
        return operation
    }

    /// 撤销最近一次文件操作。`expecting` 给了的话只在栈顶还是那一次时才撤（状态栏「已移动 … 撤销」那个按钮用：
    /// 这几秒里用户要是又做了别的，按钮不该撤错东西）。
    func undo(expecting id: UUID? = nil) {
        guard !isUndoing, !isRollingBack, let entry = undoHistory.nextUndo, id == nil || entry.id == id else { return }
        // 提交 / 推送 / 同步正在跑：这一步留在栈里，等那边做完再撤（弹出来再失败的话它就被丢掉了）
        if let problem = gitBusyProblem(for: entry) {
            showError("不能撤销\(entry.title)：\(problem.message)")
            return
        }
        _ = undoHistory.popUndo()
        isUndoing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isUndoing = false }
            switch await self.revert(entry) {
            case .done(let reverted):
                self.undoHistory.pushRedo(reverted)
                self.notify("已撤销\(entry.title)", action: BannerAction(title: "重做") { [weak self] in
                    self?.dismissBanner()
                    self?.redo()
                })
            case .failed(let reason):
                self.showError("不能撤销\(entry.title)：\(reason)")
            }
        }
    }

    func redo() {
        guard !isUndoing, !isRollingBack, let next = undoHistory.nextRedo else { return }
        if let problem = gitBusyProblem(for: next) {
            showError("不能重做\(next.title)：\(problem.message)")
            return
        }
        guard let entry = undoHistory.popRedo() else { return }
        isUndoing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isUndoing = false }
            switch await self.apply(entry) {
            case .done(let applied):
                self.undoHistory.pushUndo(applied)
                self.notify("已重做\(entry.title)", action: BannerAction(title: "撤销") { [weak self] in
                    self?.dismissBanner()
                    self?.undo()
                })
            case .failed(let reason):
                self.showError("不能重做\(entry.title)：\(reason)")
            }
        }
    }

    enum UndoOutcome {
        /// 成了；带回去的是（可能更新过的）操作，放进另一个栈。
        case done(UndoableOperation)
        case failed(String)
    }

    // MARK: - 撤销

    private func revert(_ entry: UndoableOperation) async -> UndoOutcome {
        switch entry.kind {
        case .move(let from, let to, let isDirectory, let isSymlink, let identity):
            return await moveBack(entry, node: FileNode(url: to, name: to.lastPathComponent, isDirectory: isDirectory, isSymlink: isSymlink), to: from, identity: identity)
        case .delete(let original, let trashed, _):
            guard entryExists(trashed.path) else { return .failed("废纸篓里已经没有 \(original.lastPathComponent) 了") }
            guard !entryExists(original.path) else { return .failed("原位置已经有别的东西") }
            do {
                try fileManager.moveItem(at: trashed, to: original)
            } catch {
                Log.warn("project", "从废纸篓恢复 \(original.path) 失败：\(error)")
                return .failed(error.userFacingDescription)
            }
            // 删的时候撤销历史跟着进了废纸篓（`performDelete`），搬回来接着能撤
            editorHistories?.move(from: Self.historyKey(trashed), to: Self.historyKey(original))
            Log.info("project", "已从废纸篓恢复 \(original.path)")
            refreshAll()
            revealInTree(original)
            return .done(entry)
        case .rollback(let change, let backup):
            return await restoreRolledBack(entry, change: change, backup: backup)
        case .addToGit(let untracked, let ignored):
            guard let commit else { return .failed("没有 git 仓库") }
            do {
                try await commit.unstage(paths: untracked + ignored)
            } catch {
                Log.warn("git", "撤销添加到 git 失败：\(error)")
                return .failed(error.userFacingDescription)
            }
            Log.info("git", "已把 \(untracked.count + ignored.count) 个文件从索引里撤下来")
            refreshAll()
            return .done(entry)
        case .createFolder(let url):
            guard entryExists(url.path) else { return .failed("\(url.lastPathComponent) 已经不在了") }
            guard (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { return .failed("里面已经有东西了") }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                return .failed(error.userFacingDescription)
            }
            Log.info("project", "已删掉空文件夹 \(url.path)")
            closeTabs(under: url)
            if selectedPath == url.path { select(parentOf: url) }
            refreshAll()
            return .done(entry)
        case .createFile(let url, _):
            guard (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular else {
                return .failed("文件已经被移走或替换了")
            }
            // 先保存编辑器的文字再进废纸篓，重做时才能恢复用户刚写下的内容。
            await withCheckedContinuation { continuation in saveAll { continuation.resume() } }
            guard !draftStore.isModified(EditorTab.id(forFile: url)) else { return .failed("文件未能保存，请先保存后再撤销") }
            guard let trashed = performDelete(FileNode(url: url, name: url.lastPathComponent, isDirectory: false)) else {
                return .failed(banner ?? "删不掉")
            }
            var updated = entry
            updated.kind = .createFile(url: url, trashed: trashed)
            return .done(updated)
        case .commit(let record):
            return await undoCommit(entry, record: record)
        case .batch(let operations):
            // 倒着撤：后搬的先搬回去。中途撤不成就停在那里报错，已经撤掉的那几个不再能重做（这一步整个作废）
            var reverted: [UndoableOperation] = []
            for operation in operations.reversed() {
                switch await revert(operation) {
                case .done(let done): reverted.append(done)
                case .failed(let reason): return .failed("\(operation.title)：\(reason)")
                }
            }
            var updated = entry
            updated.kind = .batch(reverted.reversed())
            return .done(updated)
        }
    }

    /// 把回滚掉的工作区内容写回去。修改：写回文件；新增：写回并重新 add；重命名：删掉回滚恢复出来的旧路径、写回新路径、
    /// 把两条都记回索引（status 才又显示成一条重命名）；删除：回滚把 HEAD 里的文件恢复了出来，撤销就是再删掉（进废纸篓）。
    private func restoreRolledBack(_ entry: UndoableOperation, change: GitChange, backup: RollbackBackup) async -> UndoOutcome {
        guard let commit, let url = url(for: change) else { return .failed("没有 git 仓库") }
        var toStage: [String] = []
        do {
            if change.kind == .deleted {
                if entryExists(url.path) { try Trash.move(url) }
            } else {
                if let originalPath = change.originalPath, !backup.originalPathExisted,
                   let originalURL = project.url(forRepositoryPath: originalPath), entryExists(originalURL.path) {
                    try Trash.move(originalURL)
                    toStage.append(originalPath)
                }
                if let data = backup.data {
                    try data.write(to: url, options: .atomic)
                    if let permissions = backup.permissions { try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                }
                if change.kind == .added || change.kind == .renamed { toStage.append(change.path) }
            }
            if !toStage.isEmpty { try await commit.stage(paths: toStage) }
        } catch {
            Log.warn("git", "撤销回滚 \(change.path) 失败：\(error)")
            refreshAll()
            return .failed(error.userFacingDescription)
        }
        Log.info("git", "已撤销回滚 \(change.path)")
        refreshAll()
        return .done(entry)
    }

    // MARK: - 重做

    private func apply(_ entry: UndoableOperation) async -> UndoOutcome {
        switch entry.kind {
        case .move(let from, let to, let isDirectory, let isSymlink, let identity):
            return await moveBack(entry, node: FileNode(url: from, name: from.lastPathComponent, isDirectory: isDirectory, isSymlink: isSymlink), to: to, identity: identity)
        case .delete(let original, _, let isDirectory):
            guard entryExists(original.path) else { return .failed("\(original.lastPathComponent) 已经不在了") }
            guard let trashed = performDelete(FileNode(url: original, name: original.lastPathComponent, isDirectory: isDirectory)) else {
                return .failed(banner ?? "删不掉")
            }
            var updated = entry
            updated.kind = .delete(original: original, trashed: trashed, isDirectory: isDirectory)
            return .done(updated)
        case .rollback(let change, _):
            guard let commit else { return .failed("没有 git 仓库") }
            guard let backup = backupForRollback(of: change) else { return .failed("文件太大，回滚之后撤不回来") }
            let succeeded = await withCheckedContinuation { continuation in
                commit.rollback(change) { continuation.resume(returning: $0) }
            }
            guard succeeded else {
                if case .failure(let text)? = commit.status { return .failed(text) }
                return .failed("回滚失败")
            }
            var updated = entry
            updated.kind = .rollback(change: change, backup: backup)
            return .done(updated)
        case .addToGit(let untracked, let ignored):
            guard let commit else { return .failed("没有 git 仓库") }
            do {
                if !untracked.isEmpty { try await commit.add(paths: untracked, force: false) }
                if !ignored.isEmpty { try await commit.add(paths: ignored, force: true) }
            } catch {
                Log.warn("git", "重做添加到 git 失败：\(error)")
                return .failed(error.userFacingDescription)
            }
            refreshAll()
            return .done(entry)
        case .createFolder(let url):
            if let failure = performCreateFolder(at: url) { return .failed(failure) }
            return .done(entry)
        case .createFile(let url, let trashed):
            guard let trashed, entryExists(trashed.path) else { return .failed("废纸篓里已经没有这个文件了") }
            guard !entryExists(url.path) else { return .failed("原位置已经有别的东西") }
            do { try fileManager.moveItem(at: trashed, to: url) }
            catch { return .failed(error.userFacingDescription) }
            didCreateFile(at: url)
            var updated = entry
            updated.kind = .createFile(url: url, trashed: nil)
            return .done(updated)
        case .commit(let record):
            return await redoCommit(entry, record: record)
        case .batch(let operations):
            var applied: [UndoableOperation] = []
            for operation in operations {
                switch await apply(operation) {
                case .done(let done): applied.append(done)
                case .failed(let reason): return .failed("\(operation.title)：\(reason)")
                }
            }
            var updated = entry
            updated.kind = .batch(applied)
            return .done(updated)
        }
    }

    // MARK: - 提交（IDEA 的 Undo Commit）

    /// 提交成功了（`CommitController.onCommitted`）：记一步撤销，状态栏给一条带「撤销」的提示。
    /// 「提交并推送」的不给按钮——推送成了就撤不了，推送失败的话 ⌘Z / 编辑 → 撤销 仍能撤。
    func didCommit(_ record: GitCommitRecord) {
        let operation = recordUndo(record.isAmend ? "修改提交" : "提交", .commit(record))
        let text = "\(record.isAmend ? "已修改提交" : "已提交") \(record.shortHash)「\(record.subject)」"
        if record.pushRequested {
            notify(text + "，正在推送")
        } else {
            notify(text, action: BannerAction(title: "撤销") { [weak self] in
                self?.dismissBanner()
                self?.undo(expecting: operation.id)
            })
        }
    }

    /// 正在提交 / 推送 / 同步 / 切分支 / 回滚时不动 HEAD。只对提交这一类有意义（文件操作不受这些影响）。
    private func gitBusyProblem(for entry: UndoableOperation) -> GitCommitUndoProblem? {
        guard case .commit(let record) = entry.kind else { return nil }
        if record.pushRequested, commit?.isPushing == true { return .pushing }
        return isGitBusy ? .busy : nil
    }

    private var isGitBusy: Bool {
        commit?.isCommitting == true || commit?.isPushing == true || isSyncingRemote || isSwitchingBranch || isRollingBack
    }

    /// 撤销 / 重做之前问 git 此刻的样子。`forRedo` 时多问一次索引的树，撤销时多问一次推送过没有。
    private func commitUndoState(_ record: GitCommitRecord, git: GitClient, repositoryRoot: URL, forRedo: Bool) async throws -> GitCommitUndo.State {
        let head = try await git.headCommit(repositoryRoot: repositoryRoot)
        let branch = try await git.symbolicBranch(repositoryRoot: repositoryRoot)
        let operation = await git.operationInProgress(repositoryRoot: repositoryRoot)
        var state = GitCommitUndo.State(head: head, branch: branch, operation: operation)
        if forRedo {
            state.indexTree = await git.indexTree(repositoryRoot: repositoryRoot)
        } else if head == record.head {
            state.isOnRemote = try await git.isCommitOnRemote(record.head, repositoryRoot: repositoryRoot)
        }
        state.wasPushed = commit?.pushedHeads.contains(record.head) == true
        state.isPushing = commit?.isPushing == true
        state.isBusy = commit?.isCommitting == true || isSyncingRemote || isSwitchingBranch || isRollingBack
        return state
    }

    /// 撤销提交：核对 → `reset --soft` → 记下此刻索引的树（重做前比对）→ 信息填回输入框、切到「提交」工具窗口。
    private func undoCommit(_ entry: UndoableOperation, record: GitCommitRecord) async -> UndoOutcome {
        guard let git, let repositoryRoot = project.repositoryRoot, commit != nil else { return .failed("没有 git 仓库") }
        do {
            let state = try await commitUndoState(record, git: git, repositoryRoot: repositoryRoot, forRedo: false)
            if let problem = GitCommitUndo.undoProblem(record, state: state) { return .failed(problem.message) }
            try await git.undoCommit(record, repositoryRoot: repositoryRoot)
        } catch {
            Log.warn("git", "撤销提交 \(record.head) 失败：\(error)")
            return .failed(error.userFacingDescription)
        }
        Log.info("git", "已撤销提交 \(record.head)（退回 \(record.previousHead ?? "还没有提交")）")
        var updated = record
        updated.indexTreeAfterUndo = await git.indexTree(repositoryRoot: repositoryRoot)
        commit?.restoreMessage(record.message)
        didMoveHead()
        var done = entry
        done.kind = .commit(updated)
        return .done(done)
    }

    private func redoCommit(_ entry: UndoableOperation, record: GitCommitRecord) async -> UndoOutcome {
        guard let git, let repositoryRoot = project.repositoryRoot, commit != nil else { return .failed("没有 git 仓库") }
        do {
            let state = try await commitUndoState(record, git: git, repositoryRoot: repositoryRoot, forRedo: true)
            if let problem = GitCommitUndo.redoProblem(record, state: state) { return .failed(problem.message) }
            try await git.redoCommit(record, repositoryRoot: repositoryRoot)
        } catch {
            Log.warn("git", "重做提交 \(record.head) 失败：\(error)")
            return .failed(error.userFacingDescription)
        }
        Log.info("git", "已重做提交 \(record.head)")
        commit?.clearMessage(ifEqualTo: record.message)
        didMoveHead(showChanges: false)
        return .done(entry)
    }

    /// HEAD 挪过之后：整体刷新（变更列表里那些文件回来 / 消失）、重拉历史；撤销的话切到「提交」工具窗口
    /// （隐藏着也亮出来）让用户看见改动回来了。重做不切：改动又进了提交，变更列表里没什么可看的。
    private func didMoveHead(showChanges: Bool = true) {
        refreshAll()
        history?.reloadIfLoaded()
        if showChanges { onRequestToolWindow?(.commit) }
    }

    /// 提交历史右键「撤销提交」能不能给：当前分支上的 HEAD，有且只有一个父提交。
    func canUndoCommitFromHistory(_ commit: GitCommit) -> Bool {
        hasGit && GitCommitUndo.historyProblem(for: commit, head: gitSnapshot.branch.headOID, branch: gitSnapshot.branch) == nil
    }

    /// 提交历史右键「撤销提交」（IDEA 的 Undo Commit）：不是本会话提交的也能撤，退回第一个父提交。
    /// 直接执行、不进撤销栈（IDEA 也是）；核对与撤销栈里的那种一样，推送过的不撤。
    func undoCommitFromHistory(_ target: GitCommit) {
        guard let git, let repositoryRoot = project.repositoryRoot, commit != nil, !isUndoing else { return }
        if let problem = GitCommitUndo.historyProblem(for: target, head: gitSnapshot.branch.headOID, branch: gitSnapshot.branch) ?? (isGitBusy ? .busy : nil) {
            showError("不能撤销提交 \(target.shortHash)：\(problem.message)")
            return
        }
        isUndoing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isUndoing = false }
            do {
                let branch = try await git.symbolicBranch(repositoryRoot: repositoryRoot)
                let record = GitCommitUndo.record(for: target, branch: branch)
                let state = try await self.commitUndoState(record, git: git, repositoryRoot: repositoryRoot, forRedo: false)
                if let problem = GitCommitUndo.undoProblem(record, state: state) {
                    self.showError("不能撤销提交 \(target.shortHash)：\(problem.message)")
                    return
                }
                try await git.undoCommit(record, repositoryRoot: repositoryRoot)
                Log.info("git", "已从提交历史撤销提交 \(target.hash)")
                // 撤销栈里记着的同一个提交已经撤掉了，留着它 ⌘Z 只会报「HEAD 已经不是这次提交了」
                self.undoHistory.removeAll { operation in
                    if case .commit(let recorded) = operation.kind { return recorded.head == target.hash }
                    return false
                }
                self.commit?.restoreMessage(record.message)
                self.didMoveHead()
                self.notify("已撤销提交 \(target.shortHash)「\(target.subject)」，改动回到了变更列表")
            } catch {
                Log.warn("git", "从提交历史撤销提交 \(target.hash) 失败：\(error)")
                self.showError("不能撤销提交 \(target.shortHash)：\(error.userFacingDescription)")
            }
        }
    }

    // MARK: - 多选

    /// 删掉选中的几个（进废纸篓），一步记进撤销栈。
    func delete(_ nodes: [FileNode]) {
        let roots = TreeSelection.roots(nodes)
        if roots.count == 1 {
            delete(roots[0])
            return
        }
        var deleted: [UndoableOperation] = []
        for node in roots {
            guard let trashed = performDelete(node) else { break }
            deleted.append(UndoableOperation(title: "删除 \(node.name)", kind: .delete(original: node.url, trashed: trashed, isDirectory: node.isDirectory)))
        }
        guard !deleted.isEmpty else { return }
        recordUndo(deleted.count == 1 ? deleted[0].title : "删除 \(deleted.count) 个项目", .batch(deleted))
    }

    /// 几个一起拖进一个目录：本来就在那个目录里的跳过（访达也不动它们），有一个放不进去就整个不放（拖动经过时光标已经说了不允许）。
    /// 全部搬完记成一步，状态栏一条「已移动 N 个项目 … 撤销」。
    func move(_ nodes: [FileNode], into directory: URL) {
        let roots = TreeSelection.roots(nodes)
        if roots.count == 1 {
            move(roots[0], into: directory)
            return
        }
        var movable: [FileNode] = []
        for node in roots {
            switch moveProblem(for: node, into: directory) {
            case nil: movable.append(node)
            case .sameDirectory?: continue
            case let problem?:
                showError("移动失败：\(node.name)：\(problem.message)")
                return
            }
        }
        guard !movable.isEmpty else { return }
        saveAll { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                var moved: [UndoableOperation] = []
                for node in movable {
                    let destination = directory.appendingPathComponent(node.name, isDirectory: node.isDirectory)
                    if let failure = await self.move(node, to: destination, verb: "移动", recording: false) {
                        self.showError(failure)
                        break
                    }
                    moved.append(UndoableOperation(title: "移动 \(node.name)", kind: .move(
                        from: node.url, to: destination, isDirectory: node.isDirectory, isSymlink: node.isSymlink, identity: self.fileIdentity(destination.path)
                    )))
                }
                guard !moved.isEmpty else { return }
                let recorded = self.recordUndo(moved.count == 1 ? moved[0].title : "移动 \(moved.count) 个项目", .batch(moved))
                let target = self.project.projectRelativeComponents(of: directory).joined(separator: "/")
                self.notify("已移动 \(moved.count) 个项目到 \(target.isEmpty ? "项目根目录" : target + "/")", action: BannerAction(title: "撤销") { [weak self] in
                    self?.dismissBanner()
                    self?.undo(expecting: recorded.id)
                })
            }
        }
    }

    /// 多选能不能一起放进这个目录：都在那个目录里了不算能放，有一个放不进去也不能放。
    func canMove(_ nodes: [FileNode], into directory: URL) -> Bool {
        let roots = TreeSelection.roots(nodes)
        var movable = 0
        for node in roots {
            switch moveProblem(for: node, into: directory) {
            case nil: movable += 1
            case .sameDirectory?: continue
            default: return false
            }
        }
        return movable > 0
    }

    /// 撤销 / 重做一次搬动：先核对要搬的那个还是当初那个文件（身份 = 设备号 + inode）、目标位置没被占，再走与重命名相同的搬法。
    private func moveBack(_ entry: UndoableOperation, node: FileNode, to destination: URL, identity: [Int]?) async -> UndoOutcome {
        guard identity != nil, fileIdentity(node.url.path) == identity else { return .failed("\(node.name) 已经不在原来的位置了") }
        guard !entryExists(destination.path) else { return .failed("\(destination.lastPathComponent) 的位置已经有别的东西") }
        // 与重命名一样先把编辑器里的写盘（搬完编辑器会重建，没送过来的几笔和撤销历史都要先收好）
        await withCheckedContinuation { continuation in saveAll { continuation.resume() } }
        if let failure = await move(node, to: destination, verb: "撤销", recording: false) { return .failed(failure) }
        return .done(entry)
    }

    // MARK: - 回滚与删除（变更列表）

    /// 回滚一条变更，先把工作区里的样子备份到内存，成了记进撤销栈。未跟踪文件的回滚就是删除，按删除记。
    func rollback(_ change: GitChange) {
        if change.kind == .untracked {
            delete(change)
            return
        }
        rollback([change])
    }

    /// 删除变更列表里的一条（进废纸篓），记进撤销栈。
    func delete(_ change: GitChange) {
        guard let commit, let url = url(for: change) else { return }
        storeEditorHistories(under: url)
        guard let trashed = commit.delete(change) else { return }
        editorHistories?.move(from: Self.historyKey(url), to: Self.historyKey(trashed))
        recordUndo("删除 \(change.fileName)", .delete(original: url, trashed: trashed, isDirectory: false))
    }

    /// 一次批量回滚最多备份这么多字节（单个文件另有 `RollbackBackup.sizeLimit`）。备份是在主线程上同步读、一直留在内存里的撤销栈里，
    /// 选几百个 Agent 生成的大文件一起回滚不能把界面卡住、把内存吃掉（1.2.1 发布前的 review 抓的）。超出的照样回滚，只是撤销不回来。
    static let batchRollbackBackupBudget = 128 * 1024 * 1024

    /// 变更列表多选之后一起回滚（IDEA 的 Rollback）：未跟踪的跳过（它们不在 git 里，要删走「删除」）。
    /// 回滚前逐个备份工作区里的样子，回滚成了的记成一步撤销。备份不了的（太大、冲突中、超出这一批的预算）照样回滚，只是撤销时不在里面。
    func rollback(_ changes: [GitChange]) {
        guard let commit, commit.canRollback, !isSyncingRemote, !isSwitchingBranch, !isUndoing else { return }
        commit.isPreparingRollback = true
        // 先收取编辑器最新的文字，备份才包含尚未送达的最后几笔。
        saveAll { [weak self] in
            commit.isPreparingRollback = false
            self?.performRollback(changes)
        }
    }

    private func performRollback(_ changes: [GitChange]) {
        guard let commit else { return }
        let targets = changes.filter { $0.kind != .untracked }
        guard !targets.isEmpty else { return }
        var backups: [String: RollbackBackup] = [:]
        var budget = Self.batchRollbackBackupBudget
        for change in targets {
            let size = url(for: change).flatMap { (try? fileManager.attributesOfItem(atPath: $0.path))?[.size] as? Int } ?? 0
            guard size <= budget, let backup = backupForRollback(of: change) else {
                Log.info("git", "\(change.path) 备份不了（太大、冲突中或超出这一批的预算），这次回滚撤销不了它")
                continue
            }
            budget -= backup.data?.count ?? 0
            backups[change.path] = backup
        }
        commit.rollback(targets) { [weak self] rolledBack in
            guard let self else { return }
            let operations = rolledBack.compactMap { change in
                backups[change.path].map { UndoableOperation(title: "回滚 \(change.fileName)", kind: .rollback(change: change, backup: $0)) }
            }
            guard !operations.isEmpty else { return }
            self.recordUndo(operations.count == 1 ? operations[0].title : "回滚 \(operations.count) 个文件", .batch(operations))
        }
    }

    /// 变更列表多选之后一起删除（进废纸篓），记成一步撤销。「已删除」的变更磁盘上没有东西，跳过。
    func delete(_ changes: [GitChange]) {
        guard let commit else { return }
        let targets = changes.filter(commit.canDelete)
        if targets.count == 1 {
            delete(targets[0])
            return
        }
        for change in targets { if let url = url(for: change) { storeEditorHistories(under: url) } }
        let operations = commit.delete(targets).compactMap { deleted in
            url(for: deleted.change).map {
                editorHistories?.move(from: Self.historyKey($0), to: Self.historyKey(deleted.trashed))
                return UndoableOperation(title: "删除 \(deleted.change.fileName)", kind: .delete(original: $0, trashed: deleted.trashed, isDirectory: false))
            }
        }
        guard !operations.isEmpty else { return }
        recordUndo(operations.count == 1 ? operations[0].title : "删除 \(operations.count) 个文件", .batch(operations))
    }

    /// 回滚前记下工作区里的样子。记不了的返回 nil（那次回滚不能撤）：文件太大（`RollbackBackup.sizeLimit`）、读不出来，
    /// 以及冲突中的文件——写回带冲突标记的文本容易，索引里三个阶段的冲突状态放不回去，「已撤销」会是假的。
    private func backupForRollback(of change: GitChange) -> RollbackBackup? {
        guard change.kind != .conflicted, let url = url(for: change) else { return nil }
        var data: Data?
        var permissions: Int?
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            guard ((attributes[.size] as? Int) ?? 0) <= RollbackBackup.sizeLimit, let contents = try? Data(contentsOf: url) else { return nil }
            data = contents
            permissions = attributes[.posixPermissions] as? Int
        }
        let originalExisted = change.originalPath.flatMap { project.url(forRepositoryPath: $0) }.map { entryExists($0.path) } ?? false
        return RollbackBackup(data: data, permissions: permissions, originalPathExisted: originalExisted)
    }
}
