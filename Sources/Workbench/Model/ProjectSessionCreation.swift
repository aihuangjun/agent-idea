import Core
import Foundation

extension ProjectSession {
    func canImportFiles(_ sources: [URL], into directory: URL) -> Bool {
        !sources.isEmpty && (try? FileImport.plan(sources, into: directory, fileManager: fileManager)) != nil
    }

    func importFiles(_ sources: [URL], into directory: URL) {
        let fileManager = self.fileManager
        Task { [weak self] in
            let (copied, failure) = await Task.detached(priority: .userInitiated) { () -> ([URL], String?) in
                var copied: [URL] = []
                do {
                    for item in try FileImport.plan(sources, into: directory, fileManager: fileManager) {
                        try fileManager.copyItem(at: item.source, to: item.destination)
                        copied.append(item.destination)
                    }
                    return (copied, nil)
                } catch {
                    return (copied, error.userFacingDescription)
                }
            }.value
            guard let self else { return }
            if let first = copied.first {
                self.refreshTree(directoryContaining: first)
                self.revealInTree(first)
                self.projectSearch.invalidate()
                self.refreshGit()
                if copied.count == 1 {
                    self.recordUndo("复制 \(first.lastPathComponent)", .createFile(url: first, trashed: nil))
                } else {
                    let operations = copied.map { UndoableOperation(title: "复制 \($0.lastPathComponent)", kind: .createFile(url: $0, trashed: nil)) }
                    self.recordUndo("复制 \(copied.count) 个文件", .batch(operations))
                }
            }
            if let failure {
                let progress = copied.isEmpty ? "" : "已复制 \(copied.count) 个文件，"
                self.showError("\(progress)复制失败：\(failure)")
            } else if !copied.isEmpty {
                self.notify("已复制 \(copied.count) 个文件")
            }
        }
    }

    /// 两种新建共用名字规则，包括失效符号链接也占名的检查。
    func newItemProblem(in directory: URL, name: String) -> FileRename.Problem? {
        FileRename.validate(name, currentName: "") { entryExists(directory.appendingPathComponent($0).path) }
    }

    /// 在指定目录下新建文件夹，展开父目录并选中，记进撤销栈。
    func createFolder(named newName: String, in directory: URL) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = newItemProblem(in: directory, name: name) {
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

    /// 不记撤销栈，供创建与重做共用。
    func performCreateFolder(at url: URL) -> String? {
        guard !entryExists(url.path) else { return "新建文件夹失败：\(FileRename.Problem.exists.message)" }
        do { try fileManager.createDirectory(at: url, withIntermediateDirectories: false) }
        catch {
            Log.warn("project", "新建文件夹 \(url.path) 失败：\(error)")
            return "新建文件夹失败：\(error.userFacingDescription)"
        }
        Log.info("project", "已新建文件夹 \(url.path)")
        refreshTree(directoryContaining: url)
        revealInTree(url)
        projectSearch.invalidate()
        return nil
    }

    /// 完整文件名由用户输入，扩展名不设白名单；创建空文件后定位并打开固定标签。
    func createFile(named newName: String, in directory: URL) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = newItemProblem(in: directory, name: name) {
            showError("新建文件失败：\(problem.message)")
            return
        }
        let url = directory.appendingPathComponent(name)
        do {
            // 校验和写盘之间有其它进程创建同名条目也不能覆盖它。
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            Log.warn("project", "新建文件 \(url.path) 失败：\(error)")
            showError("新建文件失败：\(error.userFacingDescription)")
            return
        }
        Log.info("project", "已新建文件 \(url.path)")
        didCreateFile(at: url)
        recordUndo("新建文件 \(name)", .createFile(url: url, trashed: nil))
    }

    /// 创建与重做都要刷新树、搜索和 git，并让编辑器接管这个文件。
    func didCreateFile(at url: URL) {
        refreshTree(directoryContaining: url)
        revealInTree(url)
        projectSearch.invalidate()
        refreshGit()
        openFile(url, pinned: true)
    }
}
