import Foundation

/// 变更列表的目录层级。只依赖 git 路径，已删除的文件、重命名也无需查磁盘。
public struct GitChangeTree: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        // git 可以同时报告「删除 a」和「新增 a/b」：目录与文件的路径相同，身份仍必须不同。
        public var id: String { (isDirectory ? "directory:" : "file:") + path }
        public let path: String
        public let depth: Int
        public let change: GitChange?
        /// 目录勾选作用到全部后代（包括折叠起来的），文件行只有自己。
        public let changes: [GitChange]
        public var name: String { (path as NSString).lastPathComponent }
        public var isDirectory: Bool { change == nil }
    }

    public let rows: [Row]

    public init(changes: [GitChange]) {
        let root = Directory()
        for change in changes {
            var directory = root
            for component in change.path.split(separator: "/").dropLast() {
                let name = String(component)
                if directory.directories[name] == nil { directory.directories[name] = Directory() }
                directory = directory.directories[name]!
            }
            directory.files.append(change)
        }
        rows = root.rows(parent: "", depth: 0)
    }

    /// 与界面保持同一行序：⇧连选、批量操作只使用这些行中的文件。
    public func visibleRows(collapsedDirectories: Set<String>) -> [Row] {
        var hiddenBelowDepth: Int?
        return rows.filter { row in
            if let depth = hiddenBelowDepth {
                if row.depth > depth { return false }
                hiddenBelowDepth = nil
            }
            if row.isDirectory, collapsedDirectories.contains(row.path) { hiddenBelowDepth = row.depth }
            return true
        }
    }
}

private extension GitChangeTree {
    final class Directory {
        var directories: [String: Directory] = [:]
        var files: [GitChange] = []

        func rows(parent: String, depth: Int) -> [Row] {
            var result: [Row] = []
            // 和项目目录树一致：目录在前，同层按自然顺序排列。
            for name in directories.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let path = parent.isEmpty ? name : parent + "/" + name
                let children = directories[name]!.rows(parent: path, depth: depth + 1)
                result.append(Row(path: path, depth: depth, change: nil, changes: children.compactMap(\.change)))
                result.append(contentsOf: children)
            }
            result.append(contentsOf: files.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }.map {
                Row(path: $0.path, depth: depth, change: $0, changes: [$0])
            })
            return result
        }
    }
}
