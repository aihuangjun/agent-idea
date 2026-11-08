import Foundation

/// 比较规则只作用于匹配键，两侧显示与保存的原文始终保留。
public enum DiffWhitespaceMode: String, CaseIterable, Codable, Sendable {
    case none, trailing, all

    public var label: String {
        switch self {
        case .none: return "不忽略空白"
        case .trailing: return "忽略行尾空白"
        case .all: return "忽略空格与 Tab"
        }
    }

    public func matchingKey(for line: String) -> String {
        switch self {
        case .none: return line
        case .trailing: return String(line.reversed().drop(while: Self.isHorizontalSpace).reversed())
        case .all: return String(line.filter { !Self.isHorizontalSpace($0) })
        }
    }

    private static func isHorizontalSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\r"
    }

}

public struct DiffReadingOptions: Equatable, Codable, Sendable {
    public static let defaultContextLines = 10
    static let maximumContextLines = 30
    public static let contextLineChoices = [5, defaultContextLines, maximumContextLines]

    public var collapseUnchanged: Bool
    public var contextLines: Int
    public var whitespace: DiffWhitespaceMode

    public init(collapseUnchanged: Bool = false, contextLines: Int = DiffReadingOptions.defaultContextLines, whitespace: DiffWhitespaceMode = .none) {
        self.collapseUnchanged = collapseUnchanged
        self.contextLines = max(0, min(Self.maximumContextLines, contextLines))
        self.whitespace = whitespace
    }

    private enum CodingKeys: String, CodingKey { case collapseUnchanged, contextLines, whitespace }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedContext = try values.decode(Int.self, forKey: .contextLines)
        // 旧版的 3 行选项升级为新默认值；仍受支持的用户选择继续保留。
        self.init(collapseUnchanged: try values.decode(Bool.self, forKey: .collapseUnchanged),
                  contextLines: Self.contextLineChoices.contains(savedContext) ? savedContext : Self.defaultContextLines,
                  whitespace: try values.decode(DiffWhitespaceMode.self, forKey: .whitespace))
    }
}

public struct DiffChangeRegion: Equatable, Codable, Sendable {
    public let oldStart: Int
    public let newStart: Int
    public let oldCount: Int
    public let newCount: Int
}

/// 一段可以一起折叠的未修改内容。两侧行号可以不同，数量相同。
public struct DiffContextRegion: Equatable, Codable, Sendable {
    public let oldStart: Int
    public let newStart: Int
    public let count: Int
}

/// 高亮、增删统计、上下导航与上下文折叠的共同事实源。所有位置从 0 开始。
public struct DiffReviewAnalysis: Equatable, Codable, Sendable {
    private struct LineKey: Equatable {
        let text: String
        let terminated: Bool
    }
    public let changes: [DiffChangeRegion]
    public let unchanged: [DiffContextRegion]
    public let folds: [DiffContextRegion]
    public let added: Int
    public let removed: Int
    public let oldLineCount: Int
    public let newLineCount: Int
    /// 极大幅改写时将中间区域作为一个变更，限制比较的时间和内存。
    public let simplified: Bool

    public init(oldText: String, newText: String, options: DiffReadingOptions = DiffReadingOptions()) {
        let oldLines = Self.lines(oldText), newLines = Self.lines(newText)
        // 末尾换行属于最后一行。a → a\nb 也改变了 a 的终止符，回退这一块时必须一起还原。
        func keys(_ lines: [String], text: String) -> [LineKey] {
            lines.enumerated().map { index, line in
                LineKey(text: options.whitespace.matchingKey(for: line), terminated: index < lines.count - 1 || text.hasSuffix("\n"))
            }
        }
        let oldKeys = keys(oldLines, text: oldText), newKeys = keys(newLines, text: newText)
        var prefix = 0
        while prefix < min(oldKeys.count, newKeys.count), oldKeys[prefix] == newKeys[prefix] { prefix += 1 }
        var oldEnd = oldKeys.count, newEnd = newKeys.count
        while oldEnd > prefix, newEnd > prefix, oldKeys[oldEnd - 1] == newKeys[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        let oldMiddle = Array(oldKeys[prefix..<oldEnd]), newMiddle = Array(newKeys[prefix..<newEnd])
        let edits = Self.edits(from: oldMiddle, to: newMiddle)
        simplified = edits == nil
        var regions: [DiffChangeRegion] = []
        if let edits {
            let deletions = edits.deletions, insertions = edits.insertions
            var old = 0, new = 0
            while old < oldMiddle.count || new < newMiddle.count {
                if deletions.contains(old) || insertions.contains(new) {
                    let oldStart = old, newStart = new
                    while deletions.contains(old) { old += 1 }
                    while insertions.contains(new) { new += 1 }
                    regions.append(DiffChangeRegion(oldStart: prefix + oldStart, newStart: prefix + newStart, oldCount: old - oldStart, newCount: new - newStart))
                } else { old += 1; new += 1 }
            }
        } else {
            regions = [DiffChangeRegion(oldStart: prefix, newStart: prefix, oldCount: oldMiddle.count, newCount: newMiddle.count)]
        }
        changes = regions
        added = regions.reduce(0) { $0 + $1.newCount }
        removed = regions.reduce(0) { $0 + $1.oldCount }
        oldLineCount = oldLines.count
        newLineCount = newLines.count
        var common: [DiffContextRegion] = []
        var old = 0, new = 0
        for change in regions {
            let count = min(change.oldStart - old, change.newStart - new)
            if count > 0 { common.append(DiffContextRegion(oldStart: old, newStart: new, count: count)) }
            old = change.oldStart + change.oldCount
            new = change.newStart + change.newCount
        }
        let remaining = min(oldLines.count - old, newLines.count - new)
        if remaining > 0 { common.append(DiffContextRegion(oldStart: old, newStart: new, count: remaining)) }
        unchanged = common
        let margin = max(0, min(DiffReadingOptions.maximumContextLines, options.contextLines))
        folds = common.compactMap { region in
            let before = region.oldStart == 0 && region.newStart == 0 && !regions.isEmpty ? 0 : margin
            let atEnd = region.oldStart + region.count == oldLines.count && region.newStart + region.count == newLines.count
            let after = atEnd && !regions.isEmpty ? 0 : margin
            let hidden = region.count - before - after
            guard hidden >= 5 else { return nil }
            return DiffContextRegion(oldStart: region.oldStart + before, newStart: region.newStart + before, count: hidden)
        }
    }

    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// 有界 Myers：远隔数万行的少量改动仍精确比较；大幅重写限制 D，避免二次方分配。
    private static func edits(from old: [LineKey], to new: [LineKey]) -> (deletions: Set<Int>, insertions: Set<Int>)? {
        let n = old.count, m = new.count
        if n == 0 { return ([], Set(0..<m)) }
        if m == 0 { return (Set(0..<n), []) }
        let limit = min(n + m, 512), offset = limit + 1
        guard abs(n - m) <= limit else { return nil }
        var frontier = [Int](repeating: 0, count: 2 * offset + 1)
        var trace: [[Int]] = []
        var found = false
        for distance in 0...limit {
            trace.append(frontier)
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                var x = diagonal == -distance || (diagonal != distance && frontier[offset + diagonal - 1] < frontier[offset + diagonal + 1])
                    ? frontier[offset + diagonal + 1] : frontier[offset + diagonal - 1] + 1
                var y = x - diagonal
                while x < n, y < m, old[x] == new[y] { x += 1; y += 1 }
                frontier[offset + diagonal] = x
                if x >= n, y >= m { found = true; break }
            }
            if found { break }
        }
        guard found else { return nil }
        var x = n, y = m, deletions: Set<Int> = [], insertions: Set<Int> = []
        for distance in stride(from: trace.count - 1, through: 0, by: -1) {
            let previous = trace[distance], diagonal = x - y
            let previousDiagonal = diagonal == -distance || (diagonal != distance && previous[offset + diagonal - 1] < previous[offset + diagonal + 1])
                ? diagonal + 1 : diagonal - 1
            let previousX = previous[offset + previousDiagonal], previousY = previousX - previousDiagonal
            while x > previousX, y > previousY { x -= 1; y -= 1 }
            if distance > 0 {
                if x == previousX { y -= 1; insertions.insert(y) }
                else { x -= 1; deletions.insert(x) }
            }
        }
        return (deletions, insertions)
    }
}

public struct DiffReviewProgress: Equatable, Sendable {
    public let fileIndex: Int
    public let fileCount: Int
    public let changeIndex: Int
    public let changeCount: Int

    public init(fileIndex: Int, fileCount: Int, changeIndex: Int, changeCount: Int) {
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.changeIndex = changeIndex
        self.changeCount = changeCount
    }
}
