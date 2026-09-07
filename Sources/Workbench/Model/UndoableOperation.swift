import Core
import Foundation

/// 一次能撤销的文件操作（IDEA 的 Undo 里除编辑之外的那些）：重命名 / 移动、删除、回滚。
/// 编辑器里的撤销是 CodeMirror 自己的，不在这里；焦点在哪决定 ⌘Z 撤哪一种（见 `UndoDispatcher`）。
struct UndoableOperation: Identifiable {
    enum Kind {
        /// 从 `from` 搬到了 `to`（重命名或拖拽移动）。撤销就是搬回去，重做再搬过去。
        /// `identity` 是搬过去的那个文件的身份（设备号 + inode），撤销前核对：这中间它被删了 / 改名了 / 被别的文件顶了就不能再搬。
        case move(from: URL, to: URL, isDirectory: Bool, isSymlink: Bool, identity: [Int]?)
        /// 删进了废纸篓。撤销就是从废纸篓里搬回原位；重做再删一次（废纸篓里的位置会变，重新记）。
        case delete(original: URL, trashed: URL, isDirectory: Bool)
        /// 回滚了一条变更。撤销把回滚前的工作区内容写回去；重做再回滚一次（重新备份）。
        case rollback(change: GitChange, backup: RollbackBackup)
        /// 新建了一个文件夹。撤销就是删掉它——只在它还空着的时候；重做再建一个。
        case createFolder(url: URL)
        /// 一步里做了好几件（多选之后一起拖走、一起删）：撤销按倒序逐个撤，重做按正序逐个做。
        case batch([UndoableOperation])
    }

    let id = UUID()
    /// 「重命名 a.txt」这种，菜单显示「撤销重命名 a.txt」。
    let title: String
    var kind: Kind
}

/// 回滚前工作区里的样子，撤销回滚要写回去的东西。内容放内存里（超过 `sizeLimit` 就不备份，那次回滚不能撤）。
struct RollbackBackup {
    static let sizeLimit = 32 * 1024 * 1024

    /// 变更路径上的文件内容与权限；回滚「已删除」的变更时文件本来就不在，为 nil。
    var data: Data?
    var permissions: Int?
    /// 重命名的变更回滚会把旧路径的文件恢复出来。撤销时要把它再删掉——除非回滚前旧路径上就有别的东西。
    var originalPathExisted: Bool
}
