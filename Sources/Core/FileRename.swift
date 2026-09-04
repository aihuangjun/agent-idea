import Foundation

/// 目录树里重命名文件 / 目录（IDEA 的 Rename，⇧F6）的纯逻辑：名字合不合法、初始选中哪一段、
/// 改名之后其它路径（标签、选中项、展开的目录）怎么跟着换。真正搬文件与刷新界面在 `ProjectSession`。
public enum FileRename {
    /// 名字不能用的原因，直接给用户看。
    public enum Problem: Equatable, Sendable {
        case empty
        case containsSlash
        case reserved
        case unchanged
        case exists

        public var message: String {
            switch self {
            case .empty: return "名字不能为空"
            case .containsSlash: return "名字不能包含 / 或空字符"
            case .reserved: return "这个名字不能用"
            case .unchanged: return "名字没有变"
            case .exists: return "同一目录下已经有这个名字了"
            }
        }
    }

    /// 检查新名字。`destinationExists` 由调用方看磁盘（只在名字本身没问题时才会被问）。
    /// 只改大小写（`Readme.md` → `README.md`）算改了：macOS 的文件系统多半不分大小写，`destinationExists` 会说存在，这里放行。
    public static func validate(_ newName: String, currentName: String, destinationExists: (String) -> Bool) -> Problem? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if name.contains("/") || name.contains("\0") { return .containsSlash }
        if name == "." || name == ".." { return .reserved }
        if name == currentName { return .unchanged }
        if name.lowercased() != currentName.lowercased(), destinationExists(name) { return .exists }
        return nil
    }

    /// 对话框打开时选中的那一段：IDEA 对文件选到扩展名之前（`main.swift` 选 `main`），
    /// 点文件（`.env`）、没有扩展名的、以及目录（`v1.2` 不是扩展名）整个选中。
    public static func editableRange(of name: String, isDirectory: Bool = false) -> Range<String.Index> {
        let stem = (name as NSString).deletingPathExtension
        guard !isDirectory, !stem.isEmpty, stem.count < name.count, name.hasPrefix(stem) else { return name.startIndex..<name.endIndex }
        return name.startIndex..<name.index(name.startIndex, offsetBy: stem.count)
    }

    /// 拖到另一个目录（IDEA 的 Move）做不了的原因。
    public enum MoveProblem: Equatable, Sendable {
        case sameDirectory
        case intoItself
        case exists

        public var message: String {
            switch self {
            case .sameDirectory: return "已经在这个目录里了"
            case .intoItself: return "不能移到自己或自己的子目录里"
            case .exists: return "目标目录下已经有同名的文件"
            }
        }
    }

    /// 把 `sourcePath` 搬进 `destinationDirectory`（都是绝对路径）行不行。`destinationExists` 由调用方看磁盘。
    public static func validateMove(_ sourcePath: String, into destinationDirectory: String, destinationExists: (String) -> Bool) -> MoveProblem? {
        let parent = (sourcePath as NSString).deletingLastPathComponent
        if destinationDirectory == parent { return .sameDirectory }
        if destinationDirectory == sourcePath || destinationDirectory.hasPrefix(sourcePath + "/") { return .intoItself }
        if destinationExists((destinationDirectory as NSString).appendingPathComponent((sourcePath as NSString).lastPathComponent)) { return .exists }
        return nil
    }

    /// `path` 是 `oldPath` 本身或它下面的东西时，换成新路径；否则 nil。
    public static func rewrite(_ path: String, from oldPath: String, to newPath: String) -> String? {
        if path == oldPath { return newPath }
        let prefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return newPath + "/" + path.dropFirst(prefix.count)
    }
}
