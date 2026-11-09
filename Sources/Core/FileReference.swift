import Foundation

/// 源码里的一处位置，行列都从 1 数（Agent 输出、编译器报错、IDEA 的 Go to Line 都是这个口径）。
public struct SourceLocation: Equatable, Sendable {
    public var line: Int
    /// nil 表示没给列，跳过去停在行首。
    public var column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }
}

/// 「路径:行号」这种引用的两头：复制引用时拼出来（IDEA 的 Copy Reference），
/// 查找文件 / 跳到行时从用户粘进来的文字里拆出来。纯字符串处理，不碰文件系统。
public enum FileReference {
    /// `path`、`path:12`、`path:12-20`。`lines` 为 nil（拿不到行号）就只有路径。
    public static func format(path: String, lines: ClosedRange<Int>?) -> String {
        guard let lines else { return path }
        return lines.lowerBound == lines.upperBound ? "\(path):\(lines.lowerBound)" : "\(path):\(lines.lowerBound)-\(lines.upperBound)"
    }

    /// 编辑器选区（行列从 0 数，`from` 不晚于 `to`）→ 从 1 数的行范围。
    /// 选区停在下一行行首（拖着选中几整行、或 ⇧↓ 选行时总是这样）时那一行不算——否则「选中 12–19 行」会拼成 12-20。
    public static func lineRange(fromLine: Int, fromColumn: Int, toLine: Int, toColumn: Int) -> ClosedRange<Int> {
        let forward = (fromLine, fromColumn) <= (toLine, toColumn)
        let (startLine, endLine, endColumn) = forward ? (fromLine, toLine, toColumn) : (toLine, fromLine, fromColumn)
        let start = max(0, startLine) + 1
        var end = max(0, endLine) + 1
        if endLine > startLine, endColumn == 0 { end -= 1 }
        return start...max(start, end)
    }

    /// 绝对路径相对 `root` 的形式（`/` 分隔、无前导斜杠）。就是根本身返回空串，不在根下返回 nil。
    public static func relativePath(of path: String, root: String) -> String? {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// 跳到行对话框里的输入：`12` 或 `12:5`（行:列），两头和冒号两边可以有空格。
    /// 0 当 1（超出范围的交给编辑器夹到首尾）；不是这两种格式回 nil。
    public static func parseLineColumn(_ text: String) -> SourceLocation? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let line = number(first) else { return nil }
        guard parts.count == 2 else { return SourceLocation(line: line) }
        guard let column = number(parts[1]) else { return nil }
        return SourceLocation(line: line, column: column)
    }

    /// 查找文件框里的文字 → 要搜的路径部分 + 可能带着的位置。认这些写法（都只看**末尾**，所以文件名里的冒号不受影响）：
    /// `a/b.swift:12`、`a/b.swift:12:5`、`a/b.swift:12-20`、`a/b.swift#L12`、`a/b.swift#L12-L20`、`a/b.swift#L12C5`，
    /// 编译器那种结尾多一个冒号的（`a.swift:12:5:`），外面包着反引号 / 引号的（从 Markdown 里复制来的），
    /// 前面带 `./` 的，`file://` 地址，以及项目根下的绝对路径（换成相对路径再搜）。
    /// 拆完路径部分是空的（`:12`）就不拆，原样当文件名搜。`projectRoot` 为 nil 时不换算绝对路径。
    public static func parseQuery(_ query: String, projectRoot: String?) -> (path: String, location: SourceLocation?) {
        let original = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = original
        let quotes: Set<Character> = ["`", "\"", "'"]
        while let first = text.first, let last = text.last, text.count >= 2, first == last, quotes.contains(first) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        while text.hasSuffix(":") { text.removeLast() }

        var location: SourceLocation?
        if let match = lastMatch(of: githubPattern, in: text) ?? lastMatch(of: colonPattern, in: text) {
            let path = String(text[..<match.start])
            if !path.isEmpty, let line = number(match.line) {
                text = path
                location = SourceLocation(line: line, column: match.column.flatMap(number))
            }
        }

        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { text = url.path }
        if let projectRoot, text.hasPrefix("/"), let relative = relativePath(of: text, root: projectRoot), !relative.isEmpty { text = relative }
        while text.hasPrefix("./") { text = String(text.dropFirst(2)) }
        if text.isEmpty { return (original, nil) }
        return (text, location)
    }

    // MARK: - 内部

    /// `#L12`、`#L12C5`、`#L12-L20`、`#L12-20`（GitHub / GitLab 的行锚点）。
    private static let githubPattern = try! NSRegularExpression(pattern: #"#L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?$"#)
    /// `:12`、`:12:5`、`:12-20`、`:12:5-20`。
    private static let colonPattern = try! NSRegularExpression(pattern: #":(\d+)(?::(\d+))?(?:-\d+)?$"#)

    private static func lastMatch(of pattern: NSRegularExpression, in text: String) -> (start: String.Index, line: String, column: String?)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let whole = Range(match.range, in: text), let line = Range(match.range(at: 1), in: text) else { return nil }
        let column = Range(match.range(at: 2), in: text).map { String(text[$0]) }
        return (whole.lowerBound, String(text[line]), column)
    }

    /// 纯数字 → 从 1 数的值：0 当 1，大到放不进 Int 的当 Int.max（反正会被夹到末行）。
    private static func number<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return max(1, Int(text) ?? Int.max)
    }
}
