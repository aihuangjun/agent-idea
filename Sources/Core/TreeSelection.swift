import Foundation

/// 目录树 / 变更列表的选中状态（IDEA / 访达的习惯）：单击选一个，⌘点击加减一个，⇧点击从锚点连选到这一行。
/// `anchor` 是键盘导航、重命名这些「只对一个」的操作看的那一个；`paths` 是全部选中的。纯值类型，顺序由调用方给（列表的行序）。
public struct TreeSelection: Equatable, Sendable {
    public private(set) var anchor: String?
    public private(set) var paths: Set<String> = []

    public init() {}

    public var isEmpty: Bool { paths.isEmpty }
    public var count: Int { paths.count }
    public func contains(_ path: String) -> Bool { paths.contains(path) }

    /// 只选这一个（nil 清空）。
    public mutating func select(_ path: String?) {
        anchor = path
        paths = path.map { [$0] } ?? []
    }

    /// ⌘点击：没选的加进来并成为锚点；已选的去掉，锚点落到剩下的里按行序最靠前的那个。
    public mutating func toggle(_ path: String, order: [String]) {
        if paths.contains(path) {
            paths.remove(path)
            if anchor == path { anchor = order.first { paths.contains($0) } ?? paths.first }
        } else {
            paths.insert(path)
            anchor = path
        }
    }

    /// ⇧点击：选中锚点到这一行之间的所有行（替换原来的多选，锚点不动）；没有锚点或锚点已不在行里就当单击。
    public mutating func extend(to path: String, order: [String]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: path) else {
            select(path)
            return
        }
        paths = Set(order[min(from, to)...max(from, to)])
    }

    /// 只留下还在的那些（列表刷新之后：变更被提交了、文件被删了）。锚点不在了就落到剩下的里按行序最靠前的那个。
    public mutating func retain(_ existing: Set<String>, order: [String]) {
        guard !paths.isSubset(of: existing) else { return }
        paths.formIntersection(existing)
        if let anchor, !paths.contains(anchor) { self.anchor = order.first { paths.contains($0) } ?? paths.first }
    }

    /// 选中里真正要操作的那些：祖先也被选中的去掉（搬了目录，里面的跟着走；删了目录，里面的也没了）。顺序照 `order`。
    public static func roots(_ nodes: [FileNode]) -> [FileNode] {
        nodes.filter { node in
            !nodes.contains { $0.isDirectory && node.url.path.hasPrefix($0.url.path + "/") }
        }
    }
}
