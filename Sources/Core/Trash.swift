import Foundation

/// 把文件或目录移进废纸篓。应用里所有「删除」都走这里，谁都不真的 rm——IDEA 的删除能从本地历史找回来，这里用废纸篓兜底。
/// 返回它在废纸篓里的位置（同名的会被系统改名），撤销删除就是从那里搬回来。
public enum Trash {
    @discardableResult
    public static func move(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        var trashed: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }
}
