import Foundation

/// 目录树上的一个节点。**只描述磁盘上的事实**，git 状态由另一层叠上去。
public struct FileNode: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool

    public init(url: URL, name: String, isDirectory: Bool, isSymlink: Bool = false) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

/// 列一个目录。
///
/// 排序照 IDEA：目录在前、文件在后，各自按名字不分大小写排。`.git` 永远不列——
/// 它不是项目内容，而且里面几千个对象文件会把树撑爆。其它点文件照常显示（`.gitignore`、`.env` 是要看的）。
public enum DirectoryLister {
    public static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    public static func list(_ directory: URL, fileManager: FileManager = .default) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        var nodes: [FileNode] = []
        nodes.reserveCapacity(contents.count)
        for listed in contents {
            let name = listed.lastPathComponent
            if hiddenNames.contains(name) { continue }
            let values = try? listed.resourceValues(forKeys: Set(keys))
            // 子节点的 URL 用「父路径 + 名字」拼，而不是用列出来的那个：
            // FileManager 会把父路径里的符号链接解析掉（/var → /private/var），树上的路径就跟根对不上了。
            let url = directory.appendingPathComponent(name, isDirectory: values?.isDirectory ?? false)
            let isSymlink = values?.isSymbolicLink ?? false
            // 符号链接指向目录的也当目录展开，但不解析到真实路径：树上显示的是项目里的名字。
            var isDirectory = values?.isDirectory ?? false
            if isSymlink {
                var resolvedIsDirectory: ObjCBool = false
                let resolved = url.resolvingSymlinksInPath().path
                isDirectory = fileManager.fileExists(atPath: resolved, isDirectory: &resolvedIsDirectory) && resolvedIsDirectory.boolValue
            }
            nodes.append(FileNode(url: url, name: name, isDirectory: isDirectory, isSymlink: isSymlink))
        }
        return sorted(nodes)
    }

    public static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.name < rhs.name
        }
    }
}

/// 展开状态 + 每个目录的子节点缓存 → 一列可见行。
///
/// 树是**扁平化渲染**的：SwiftUI 的 `OutlineGroup` 要求整棵树的数据预先就位，
/// 而一个工作区里的 `node_modules` 可能有几万个文件，只能按展开惰性列目录。
public struct FlattenedTree: Sendable {
    public struct Row: Equatable, Hashable, Sendable, Identifiable {
        public var id: String { node.id }
        public let node: FileNode
        public let depth: Int
        public let isExpanded: Bool

        public init(node: FileNode, depth: Int, isExpanded: Bool) {
            self.node = node
            self.depth = depth
            self.isExpanded = isExpanded
        }
    }

    public private(set) var children: [String: [FileNode]] = [:]
    public private(set) var expanded: Set<String> = []

    public init() {}

    public func isExpanded(_ path: String) -> Bool { expanded.contains(path) }
    public func hasLoaded(_ path: String) -> Bool { children[path] != nil }

    public mutating func setChildren(_ nodes: [FileNode], for path: String) {
        children[path] = nodes
    }

    public mutating func expand(_ path: String) { expanded.insert(path) }
    public mutating func collapse(_ path: String) { expanded.remove(path) }
    public mutating func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// 把全部子节点缓存作废（⌘R 手动刷新）。展开状态保留，下一次 `rows(root:)` 前按需重列。
    public mutating func invalidateAll() { children.removeAll() }

    /// 一个节点改了名（或挪了地方）：它和它下面的目录展开状态跟着换路径；这些目录的子节点缓存作废
    /// （里面节点的 URL 还是旧的），父目录也要重列。都由下一次 `rows(root:)` 前的 `needsLoading` 补加载。
    public mutating func rename(_ path: String, to newPath: String) {
        expanded = Set(expanded.map { FileRename.rewrite($0, from: path, to: newPath) ?? $0 })
        for key in children.keys where FileRename.rewrite(key, from: path, to: newPath) != nil {
            children[key] = nil
        }
        children[(path as NSString).deletingLastPathComponent] = nil
    }

    /// 从根开始按深度优先展开成可见行。根本身不出现在行里。
    /// 目录已展开但子节点还没加载时不产生子行——由调用方看到 `needsLoading` 去加载。
    public func rows(root: String) -> [Row] {
        var rows: [Row] = []
        func walk(_ path: String, depth: Int) {
            guard let nodes = children[path] else { return }
            for node in nodes {
                let isExpanded = node.isDirectory && expanded.contains(node.id)
                rows.append(Row(node: node, depth: depth, isExpanded: isExpanded))
                if isExpanded { walk(node.id, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return rows
    }

    /// 已展开但还没有列过内容的目录（含根）。
    public func needsLoading(root: String) -> [String] {
        var pending: [String] = []
        if children[root] == nil { pending.append(root) }
        for path in expanded where children[path] == nil && path != root {
            pending.append(path)
        }
        return pending
    }

    /// 让某个文件在树上可见：把它的每一级祖先都展开。新展开的目录由下一次 `rows(root:)` 前的 `needsLoading` 补加载。
    public mutating func reveal(_ path: String, root: String) {
        var current = (path as NSString).deletingLastPathComponent
        while current.count >= root.count, current.hasPrefix(root) {
            if current == root { break }
            expanded.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
    }
}
