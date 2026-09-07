import Core
import Foundation

/// 文件操作的撤销 / 重做（IDEA 的 Undo / Redo 里编辑之外的那部分）：重命名、移动、删除、回滚。
/// 栈是 `UndoHistory`（Core，纯逻辑）；这里管每一种操作怎么撤、怎么重做，以及撤不成时怎么说。
/// 撤销前先核对磁盘：这中间文件被删了、改名了、原位置被别的东西占了，就报错并把这一步丢掉（留着下次还是撤不成）。
extension ProjectSession {
    var canUndo: Bool { undoHistory.canUndo }
    var canRedo: Bool { undoHistory.canRedo }
    /// 菜单项标题：「撤销重命名 a.txt」；没有可撤的就是「撤销」。
    var undoTitle: String { undoHistory.nextUndo.map { "撤销" + $0.title } ?? "撤销" }
    var redoTitle: String { undoHistory.nextRedo.map { "重做" + $0.title } ?? "重做" }

    @discardableResult
    func recordUndo(_ title: String, _ kind: UndoableOperation.Kind) -> UndoableOperation {
        let operation = UndoableOperation(title: title, kind: kind)
        undoHistory.record(operation)
        return operation
    }

    /// 撤销最近一次文件操作。`expecting` 给了的话只在栈顶还是那一次时才撤（状态栏「已移动 … 撤销」那个按钮用：
    /// 这几秒里用户要是又做了别的，按钮不该撤错东西）。
    func undo(expecting id: UUID? = nil) {
        guard !isUndoing, let entry = undoHistory.nextUndo, id == nil || entry.id == id else { return }
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
        guard !isUndoing, let entry = undoHistory.popRedo() else { return }
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
            Log.info("project", "已从废纸篓恢复 \(original.path)")
            refreshAll()
            revealInTree(original)
            return .done(entry)
        case .rollback(let change, let backup):
            return await restoreRolledBack(entry, change: change, backup: backup)
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
        case .createFolder(let url):
            if let failure = performCreateFolder(at: url) { return .failed(failure) }
            return .done(entry)
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

    // MARK: - 新建文件夹

    /// 新建文件夹能不能用这个名字（对话框边敲边检查）。
    func newFolderProblem(in directory: URL, name: String) -> FileRename.Problem? {
        FileRename.validate(name, currentName: "") { entryExists(directory.appendingPathComponent($0).path) }
    }

    /// 在目录下新建一个文件夹（IDEA 的 New → Directory）：建好后展开父目录、露出并选中，记进撤销栈。
    func createFolder(named newName: String, in directory: URL) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = newFolderProblem(in: directory, name: name) {
            showError("新建文件夹失败：\(problem.message)")
            return
        }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        if let failure = performCreateFolder(at: url) {
            showError(failure)
            return
        }
        recordUndo("新建文件夹 \(name)", .createFolder(url: url))
    }

    /// 真正建、树上露出来；不记撤销栈（重做也走这里）。返回给用户看的失败原因，成了 nil。
    private func performCreateFolder(at url: URL) -> String? {
        guard !entryExists(url.path) else { return "新建文件夹失败：\(FileRename.Problem.exists.message)" }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            Log.warn("project", "新建文件夹 \(url.path) 失败：\(error)")
            return "新建文件夹失败：\(error.userFacingDescription)"
        }
        Log.info("project", "已新建文件夹 \(url.path)")
        refreshTree(directoryContaining: url)
        revealInTree(url)
        search.applyChanges([url.path])
        return nil
    }

    // MARK: - 回滚与删除（变更列表）

    /// 回滚一条变更，先把工作区里的样子备份到内存，成了记进撤销栈。未跟踪文件的回滚就是删除，按删除记。
    func rollback(_ change: GitChange) {
        guard let commit else { return }
        if change.kind == .untracked {
            delete(change)
            return
        }
        let backup = backupForRollback(of: change)
        if backup == nil { Log.info("git", "\(change.path) 太大，这次回滚不能撤销") }
        commit.rollback(change) { [weak self] succeeded in
            guard let self, succeeded, let backup else { return }
            self.recordUndo("回滚 \(change.fileName)", .rollback(change: change, backup: backup))
        }
    }

    /// 删除变更列表里的一条（进废纸篓），记进撤销栈。
    func delete(_ change: GitChange) {
        guard let commit, let url = url(for: change), let trashed = commit.delete(change) else { return }
        recordUndo("删除 \(change.fileName)", .delete(original: url, trashed: trashed, isDirectory: false))
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
