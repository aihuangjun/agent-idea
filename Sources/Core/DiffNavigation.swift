public enum DiffNavigationDirection: String, Sendable {
    case next, previous

    public var entryEdge: DiffEdge { self == .next ? .first : .last }
}

/// 跨文件导航明确指定落在第一处还是最后一处，优先于标签原先记住的位置。
public enum DiffEdge: String, Codable, Sendable {
    case first, last
}

public enum DiffFileNavigation {
    public static func adjacentPath(in paths: [String], current: String, direction: DiffNavigationDirection) -> String? {
        guard let index = paths.firstIndex(of: current) else { return nil }
        let target = index + (direction == .next ? 1 : -1)
        return paths.indices.contains(target) ? paths[target] : nil
    }
}
