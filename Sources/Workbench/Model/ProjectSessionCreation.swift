import Core
import Foundation

extension ProjectSession {
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
        search.applyChanges([url.path])
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
        search.applyChanges([url.path])
        refreshGit()
        openFile(url, pinned: true)
    }
}
