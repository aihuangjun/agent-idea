import Foundation

/// 把 diff 排成表格行，给前端直接画。
///
/// 配对算法在这里而不是 JS 里：这是有分支、会出错的逻辑，Swift 侧能测。
public enum DiffLayout {
    public struct Cell: Equatable, Sendable, Encodable {
        public enum Kind: String, Sendable, Encodable {
            case context = "ctx"
            case added = "add"
            case removed = "del"
            /// 对面有行、这边没有：并排视图里的占位。
            case empty
        }

        public let number: Int?
        public let text: String
        public let kind: Kind

        public init(number: Int?, text: String, kind: Kind) {
            self.number = number
            self.text = text
            self.kind = kind
        }

        public static let blank = Cell(number: nil, text: "", kind: .empty)

        enum CodingKeys: String, CodingKey { case number = "n", text = "t", kind = "k" }
    }

    /// 并排视图的一行。
    public enum SideBySideRow: Equatable, Sendable, Encodable {
        case hunk(String)
        case pair(left: Cell, right: Cell)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hunk(let text):
                try container.encode("hunk", forKey: .type)
                try container.encode(text, forKey: .text)
            case .pair(let left, let right):
                try container.encode("line", forKey: .type)
                try container.encode(left, forKey: .left)
                try container.encode(right, forKey: .right)
            }
        }

        enum CodingKeys: String, CodingKey { case type, text, left = "l", right = "r" }
    }

    /// 统一视图的一行。
    public enum UnifiedRow: Equatable, Sendable, Encodable {
        case hunk(String)
        case line(DiffLine)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hunk(let text):
                try container.encode("hunk", forKey: .type)
                // hunk 行的键与并排视图一致叫 `text`，行内容才缩写成 `t`——render.js 两种模式共用一个 hunkRow
                try container.encode(text, forKey: .hunkText)
            case .line(let line):
                try container.encode("line", forKey: .type)
                try container.encode(line.oldNumber, forKey: .oldNumber)
                try container.encode(line.newNumber, forKey: .newNumber)
                try container.encode(line.text, forKey: .text)
                try container.encode(line.kind.rawValue, forKey: .kind)
            }
        }

        enum CodingKeys: String, CodingKey { case type, hunkText = "text", text = "t", oldNumber = "o", newNumber = "n", kind = "k" }
    }

    /// 并排：一段连续的删除紧跟一段连续的新增时逐行配对，多出来的一侧对空白；上下文两边都有。
    public static func sideBySide(_ diff: FileDiff) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        for hunk in diff.hunks {
            rows.append(.hunk(hunk.header))
            var removed: [DiffLine] = []
            var added: [DiffLine] = []

            func flush() {
                let count = max(removed.count, added.count)
                for index in 0..<count {
                    let left = index < removed.count
                        ? Cell(number: removed[index].oldNumber, text: removed[index].text, kind: .removed)
                        : .blank
                    let right = index < added.count
                        ? Cell(number: added[index].newNumber, text: added[index].text, kind: .added)
                        : .blank
                    rows.append(.pair(left: left, right: right))
                }
                removed = []
                added = []
            }

            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    // 删除段出现在新增段之后，说明是新的一组改动
                    if !added.isEmpty { flush() }
                    removed.append(line)
                case .added:
                    added.append(line)
                case .context:
                    flush()
                    rows.append(.pair(
                        left: Cell(number: line.oldNumber, text: line.text, kind: .context),
                        right: Cell(number: line.newNumber, text: line.text, kind: .context)
                    ))
                }
            }
            flush()
        }
        return rows
    }

    public static func unified(_ diff: FileDiff) -> [UnifiedRow] {
        var rows: [UnifiedRow] = []
        for hunk in diff.hunks {
            rows.append(.hunk(hunk.header))
            rows.append(contentsOf: hunk.lines.map(UnifiedRow.line))
        }
        return rows
    }
}
