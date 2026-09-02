import Foundation

/// unified diff 里的一行。
public struct DiffLine: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let text: String
    /// 在旧文件里的行号（新增行没有）。
    public let oldNumber: Int?
    /// 在新文件里的行号（删除行没有）。
    public let newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Equatable, Hashable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// `@@ ... @@` 后面那段函数名上下文。
    public let heading: String
    public let lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
    }

    public var header: String {
        var text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !heading.isEmpty { text += " " + heading }
        return text
    }
}

/// 一个文件的 diff。
public struct FileDiff: Equatable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    public let isBinary: Bool
    public let hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, isBinary: Bool, hunks: [DiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.hunks = hunks
    }

    public var addedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var removedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    public var isEmpty: Bool { hunks.isEmpty && !isBinary }
}

/// 解析 `git diff` 的输出。只取第一个文件——我们每次只问一个路径。
public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> FileDiff {
        var oldPath: String?
        var newPath: String?
        var isBinary = false
        var hunks: [DiffHunk] = []

        var currentHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)?
        var currentLines: [DiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var seenFileHeader = false

        func flush() {
            if let header = currentHeader {
                hunks.append(DiffHunk(
                    oldStart: header.oldStart, oldCount: header.oldCount,
                    newStart: header.newStart, newCount: header.newCount,
                    heading: header.heading, lines: currentLines
                ))
            }
            currentHeader = nil
            currentLines = []
        }

        // 按行切但保留空行：diff 里的空上下文行是 " " 一个空格，split 会把它留住；
        // 真正的空行（没有前导字符）只出现在末尾。
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                // 第二个文件开始了，我们只要第一个
                if seenFileHeader { break }
                seenFileHeader = true
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
                continue
            }
            if line.hasPrefix("--- ") {
                oldPath = stripPathPrefix(String(line.dropFirst(4)))
                continue
            }
            if line.hasPrefix("+++ ") {
                newPath = stripPathPrefix(String(line.dropFirst(4)))
                continue
            }
            if line.hasPrefix("@@") {
                flush()
                guard let header = parseHunkHeader(line) else { continue }
                currentHeader = header
                oldNumber = header.oldStart
                newNumber = header.newStart
                continue
            }
            guard currentHeader != nil else { continue }
            if line.hasPrefix("\\") {
                // "\ No newline at end of file"：不是内容，不占行号
                continue
            }
            let marker = line.first ?? " "
            let content = line.isEmpty ? "" : String(line.dropFirst())
            switch marker {
            case "+":
                currentLines.append(DiffLine(kind: .added, text: content, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            case "-":
                currentLines.append(DiffLine(kind: .removed, text: content, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            default:
                currentLines.append(DiffLine(kind: .context, text: content, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            }
        }
        flush()

        return FileDiff(oldPath: oldPath, newPath: newPath, isBinary: isBinary, hunks: hunks)
    }

    /// `a/foo.swift` → `foo.swift`；`/dev/null` → nil。
    static func stripPathPrefix(_ raw: String) -> String? {
        // 路径后面可能跟着制表符和时间戳（某些 diff 变体），只取制表符前面
        let path = raw.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? raw
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// `@@ -1,5 +1,7 @@ func foo()` 。省略的计数按 1 算（`-3 +3,4`）。
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)? {
        guard let closing = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: 2)..<closing.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard ranges.count == 2 else { return nil }
        func parse(_ token: Substring) -> (Int, Int)? {
            let body = token.dropFirst() // 去掉 - 或 +
            let parts = body.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 1
            return (start, count)
        }
        guard let old = parse(ranges[0]), let new = parse(ranges[1]) else { return nil }
        let heading = line[closing.upperBound...].trimmingCharacters(in: .whitespaces)
        return (old.0, old.1, new.0, new.1, heading)
    }
}
