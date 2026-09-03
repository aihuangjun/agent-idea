import Foundation

/// 把文件或目录移进废纸篓。应用里所有「删除」都走这里，谁都不真的 rm——IDEA 的删除能从本地历史找回来，这里用废纸篓兜底。
public enum Trash {
    public static func move(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }
}
