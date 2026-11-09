import Foundation

/// 全项目文本搜索（IDEA 的 Find in Path）的纯逻辑：查询参数、行内命中范围、`git grep -z` 输出解析、
/// 结果分组与截断、长行取样，以及不在 git 仓库里时逐个读文件的退路。
///
/// **位置一律是 UTF-16 下标**（行内从 0 数）：CodeMirror 的 `ch`、JS 字符串、`NSRegularExpression` 的 NSRange 都是这个口径。
/// `Character`（字素簇）不行——emoji、组合字符会差出几位；git `--column` 给的是字节偏移，解析时换算过来。
public struct TextSearchQuery: Equatable, Sendable {
    public var text: String
    public var caseSensitive: Bool
    public var wholeWords: Bool
    public var isRegex: Bool
    /// 文件掩码，逗号分隔：`*.swift, !*Tests.swift`。不带 `/` 的按文件名匹配，带 `/` 的按相对项目根的路径匹配（支持 `**`）；
    /// `!` 开头的是排除。空 = 所有文件。
    public var fileMask: String

    public init(text: String, caseSensitive: Bool = false, wholeWords: Bool = false, isRegex: Bool = false, fileMask: String = "") {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWords = wholeWords
        self.isRegex = isRegex
        self.fileMask = fileMask
    }

    /// 没东西可搜（空串在 git grep 里匹配每一行）。
    public var isEmpty: Bool { text.isEmpty }

    /// 编辑器里选中的文字能不能拿来预填（IDEA 也这样）：只认单行、不全是空白、不太长；正则模式下转义成字面量。
    public static func prefill(fromSelection selection: String?, isRegex: Bool) -> String? {
        guard let selection, !selection.isEmpty, selection.count <= 200,
              !selection.contains(where: \.isNewline),
              !selection.allSatisfy(\.isWhitespace) else { return nil }
        return isRegex ? NSRegularExpression.escapedPattern(for: selection) : selection
    }

    /// 掩码拆成包含 / 排除两组（去掉空项与 `!`）。
    public var maskPatterns: (include: [String], exclude: [String]) {
        var include: [String] = [], exclude: [String] = []
        for raw in fileMask.split(separator: ",") {
            let pattern = raw.trimmingCharacters(in: .whitespaces)
            if pattern.hasPrefix("!") {
                let rest = pattern.dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { exclude.append(rest) }
            } else if !pattern.isEmpty {
                include.append(pattern)
            }
        }
        return (include, exclude)
    }

    /// `git grep` 的参数（在项目根目录里跑，输出的路径就是相对项目根的）。
    ///
    /// - 前面的 `-c` 把会改输出形状的用户配置钉死：`grep.fullName=true` 会让路径改成相对**仓库根**（项目是仓库子目录时
    ///   拼出来的文件路径就错了，git grep 又没有 `--no-full-name`）；`grep.fallbackToNoIndex=true` 会让仓库外的目录
    ///   改走 `--no-index`，与 `--untracked` 冲突报错，认不出「不在仓库里」。`-n --column -F/-P/-E` 显式给了，盖得住其余几项 grep.* 配置。
    /// - `--untracked`：Agent 新建、还没 add 的文件也要搜到；被 .gitignore 忽略的照样不搜（这是 git grep 的默认）。
    /// - `-I` 跳过二进制，`-n --column` 行号与列（列是**字节**偏移），`-z` 让文件名原样输出（带冒号 / 空格 / 中文都能拆），`--no-color`。
    /// - 纯文本 `-F`；正则用 `-P`（PCRE，与界面上校验用的 ICU 语法最接近），git 没编进 PCRE 时调用方换 `perl: false` 退回 `-E`。
    /// - 掩码转成 pathspec：不带 `/` 的写成 `:(glob)**/<掩码>`（任意目录下按文件名），带 `/` 的 `:(glob)<掩码>`，排除的加 `exclude`。
    public func gitGrepArguments(perl: Bool = true) -> [String] {
        var arguments = ["-c", "grep.fullName=false", "-c", "grep.fallbackToNoIndex=false",
                         "grep", "--untracked", "-I", "-n", "--column", "-z", "--no-color"]
        if !caseSensitive { arguments.append("-i") }
        if wholeWords { arguments.append("-w") }
        arguments.append(isRegex ? (perl ? "-P" : "-E") : "-F")
        arguments += ["-e", text, "--"]
        let masks = maskPatterns
        arguments += masks.include.map { Self.pathspec($0, exclude: false) }
        arguments += masks.exclude.map { Self.pathspec($0, exclude: true) }
        return arguments
    }

    private static func pathspec(_ pattern: String, exclude: Bool) -> String {
        // icase：macOS 的文件系统默认不分大小写，`*.SWIFT` 也该找到 `a.swift`；逐个读文件的退路同样不分
        let magic = exclude ? "glob,icase,exclude" : "glob,icase"
        let body = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        return body.contains("/") ? ":(\(magic))\(body)" : ":(\(magic))**/\(body)"
    }

    /// 相对路径过不过掩码（不在 git 仓库里、逐个读文件时用；语义与上面的 pathspec 一致）。
    public func matchesMask(_ relativePath: String) -> Bool {
        let masks = maskPatterns
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        func matches(_ pattern: String) -> Bool {
            let body = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
            return body.contains("/") ? Glob.matches(body, relativePath) : Glob.matches(body, name)
        }
        if masks.exclude.contains(where: matches) { return false }
        return masks.include.isEmpty || masks.include.contains(where: matches)
    }
}

/// 搜索参数不对（给人看的话）。
public enum TextSearchError: Error, Equatable, LocalizedError {
    case invalidRegex(String)
    case failed(String)
    /// 目录不在 git 仓库里（`git grep` 报 not a git repository）：调用方退回逐个读文件。
    case notARepository

    public var errorDescription: String? {
        switch self {
        case .invalidRegex(let detail): return detail
        case .failed(let detail): return detail
        case .notARepository: return "不在 git 仓库里"
        }
    }
}

/// 在一行里找出全部命中（UTF-16 范围）。git 只告诉我们哪一行命中、第一处在哪，一行里好几处要自己再找一遍，
/// 所以这里与 git grep 用同样的语义：纯文本 / 正则、区分大小写、全词（词字符是 ASCII 的字母数字和下划线，与 git `-w` 一致）。
public struct TextSearchMatcher: @unchecked Sendable {
    // NSRegularExpression 不可变、可跨线程用，所以 @unchecked
    private let regex: NSRegularExpression

    public init(_ query: TextSearchQuery) throws {
        guard !query.text.isEmpty else { throw TextSearchError.invalidRegex("输入要查找的文字") }
        var pattern = query.isRegex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        if query.wholeWords { pattern = "(?<![A-Za-z0-9_])(?:\(pattern))(?![A-Za-z0-9_])" }
        do {
            regex = try NSRegularExpression(pattern: pattern, options: query.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw TextSearchError.invalidRegex(Self.explain(query.text))
        }
    }

    /// 命中范围，UTF-16 下标，按位置排好；空匹配（`a*` 在没有 a 的地方）不算。
    public func ranges(in line: String) -> [Range<Int>] {
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .map(\.range)
            .filter { $0.length > 0 }
            .map { $0.location..<($0.location + $0.length) }
    }

    /// 正则写错了：尽量说清楚错在哪，最后总给一条出路（不想用正则就关掉）。
    static func explain(_ pattern: String) -> String {
        var depth = 0, bracket = false, escaped = false
        var unbalancedParen = false
        for character in pattern {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "[": if !bracket { bracket = true }
            case "]": bracket = false
            case "(" where !bracket: depth += 1
            case ")" where !bracket:
                depth -= 1
                if depth < 0 { unbalancedParen = true }
            default: break
            }
        }
        let reason: String
        if escaped {
            reason = "末尾多了一个 \\"
        } else if bracket {
            reason = "方括号 [ ] 没有配对"
        } else if depth != 0 || unbalancedParen {
            reason = "圆括号 ( ) 没有配对"
        } else if let first = pattern.first, "*+?{".contains(first) {
            reason = "开头的 \(first) 前面没有可以重复的东西"
        } else {
            reason = "语法不对"
        }
        return "正则表达式有误：\(reason)。要按普通文字查找，关掉「.*」（正则）。"
    }
}

/// 一行命中。
public struct TextSearchLine: Equatable, Sendable, Identifiable {
    /// 从 1 数。
    public let line: Int
    /// 整行文字（去掉了行尾的 `\r`）。
    public let text: String
    /// 命中范围（UTF-16，可能是空数组：git 认为命中、我们自己却没找出来——正则方言差异、文件不是 UTF-8）。
    public let ranges: [Range<Int>]
    /// 跳过去时光标放在哪一列（UTF-16，从 0 数）：第一处命中的开头。
    public let column: Int

    public init(line: Int, text: String, ranges: [Range<Int>], column: Int) {
        self.line = line
        self.text = text
        self.ranges = ranges
        self.column = column
    }

    public var id: Int { line }
    /// 这一行算几处匹配（找不出范围的按 1 处算）。
    public var matchCount: Int { max(1, ranges.count) }
    /// 打开后选中多长（第一处命中的长度；不知道就 0，只放光标）。
    public var selectionLength: Int { ranges.first.map { $0.count } ?? 0 }
}

/// 一个文件里的全部命中行。
public struct TextSearchFile: Equatable, Sendable, Identifiable {
    /// 相对项目根，`/` 分隔。
    public let path: String
    public internal(set) var lines: [TextSearchLine]

    public init(path: String, lines: [TextSearchLine]) {
        self.path = path
        self.lines = lines
    }

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// 所在目录（相对项目根），根下的文件是空串。
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
    public var matchCount: Int { lines.reduce(0) { $0 + $1.matchCount } }
}

/// 一次搜索的结果：按文件分组，文件按出现顺序（git grep 按路径排好了）。
public struct TextSearchResult: Equatable, Sendable {
    public internal(set) var files: [TextSearchFile] = []
    public internal(set) var matchCount = 0
    /// 结果太多，后面的没收（界面上提示「只显示前 N 处」）。
    public internal(set) var isTruncated = false

    public init(files: [TextSearchFile] = [], matchCount: Int? = nil, isTruncated: Bool = false) {
        self.files = files
        self.matchCount = matchCount ?? files.reduce(0) { $0 + $1.matchCount }
        self.isTruncated = isTruncated
    }

    public var lineCount: Int { files.reduce(0) { $0 + $1.lines.count } }
}

/// 边收边分组、到上限就停。git 的输出与逐个读文件的退路共用。
public struct TextSearchCollector {
    public let limit: Int
    public private(set) var result = TextSearchResult()
    private var fileIndex: [String: Int] = [:]

    public init(limit: Int) {
        self.limit = limit
    }

    /// 收一行。回 false 表示到上限了，别再喂（这一行没收，结果标成截断）。
    /// 上限按「处」算；一行里有好几处、收进来会超的，这一行不收——显示的总数不超过上限（第一行例外，一行就超了也收下）。
    @discardableResult
    public mutating func add(path: String, line: TextSearchLine) -> Bool {
        guard !result.isTruncated else { return false }
        if result.matchCount >= limit || (result.matchCount > 0 && result.matchCount + line.matchCount > limit) {
            result.isTruncated = true
            return false
        }
        if let index = fileIndex[path] {
            result.files[index].lines.append(line)
        } else {
            fileIndex[path] = result.files.count
            result.files.append(TextSearchFile(path: path, lines: [line]))
        }
        result.matchCount += line.matchCount
        return true
    }

    /// 输入还有、但我们不再要了（调用方自己知道后面还有东西时调）。
    public mutating func markTruncated() { result.isTruncated = true }
}

/// `git grep -n --column -z` 的输出：每条是 `路径\0行号\0列\0这一行\n`（列是从 1 数的**字节**偏移）。
public enum GitGrepParser {
    public static func parse(_ data: Data, matcher: TextSearchMatcher, limit: Int) -> TextSearchResult {
        var collector = TextSearchCollector(limit: limit)
        let bytes = [UInt8](data)
        var index = 0
        /// 读到下一个 `terminator` 为止（不含）；读不到（输出被截断）回 nil。
        func field(until terminator: UInt8) -> ArraySlice<UInt8>? {
            guard let end = bytes[index...].firstIndex(of: terminator) else { return nil }
            defer { index = end + 1 }
            return bytes[index..<end]
        }
        while index < bytes.count {
            guard let pathBytes = field(until: 0), let lineBytes = field(until: 0), let columnBytes = field(until: 0) else { break }
            // 最后一行可能没有换行符（输出被截断时也是这样）：剩下的都算这一行
            let textBytes = field(until: 10) ?? {
                defer { index = bytes.count }
                return bytes[index...]
            }()
            guard let lineNumber = Int(String(decoding: lineBytes, as: UTF8.self)) else { continue }
            let byteColumn = Int(String(decoding: columnBytes, as: UTF8.self)) ?? 1
            var content = textBytes
            if content.last == 13 { content = content.dropLast() }       // CRLF 文件
            let text = String(decoding: content, as: UTF8.self)
            let ranges = matcher.ranges(in: text)
            let column = ranges.first?.lowerBound ?? utf16Offset(ofByte: byteColumn - 1, in: content)
            let line = TextSearchLine(line: lineNumber, text: text, ranges: ranges, column: column)
            if !collector.add(path: String(decoding: pathBytes, as: UTF8.self), line: line) { break }
        }
        return collector.result
    }

    /// 行内的字节偏移（从 0 数）→ UTF-16 偏移。落在一个多字节字符中间的，按这个字符的开头算。
    public static func utf16Offset(ofByte byteOffset: Int, in line: ArraySlice<UInt8>) -> Int {
        guard byteOffset > 0 else { return 0 }
        var end = line.startIndex + min(byteOffset, line.count)
        // 往回退到字符边界：UTF-8 的后续字节是 10xxxxxx
        while end > line.startIndex, end < line.endIndex, line[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: line[line.startIndex..<end], as: UTF8.self).utf16.count
    }
}

/// 列表里显示的一行：去掉缩进，太长的以第一处命中为中心截一段，两头加省略号；范围跟着平移、裁剪。
public struct TextSearchSnippet: Equatable, Sendable {
    public let text: String
    /// UTF-16，相对 `text`。
    public let ranges: [Range<Int>]

    public static func make(_ line: TextSearchLine, maxLength: Int = 160, leadingContext: Int = 40) -> TextSearchSnippet {
        let units = Array(line.text.utf16)
        var start = 0, end = units.count
        // 缩进与行尾空白不显示（IDEA 也这样）；空白都是单个 UTF-16 单元，下标好算
        while start < end, units[start] == 0x20 || units[start] == 0x09 { start += 1 }
        while end > start, units[end - 1] == 0x20 || units[end - 1] == 0x09 { end -= 1 }
        let anchor = line.ranges.first?.lowerBound ?? line.column
        var prefix = "", suffix = ""
        if end - start > maxLength {
            let windowStart = max(start, min(anchor - leadingContext, end - maxLength))
            if windowStart > start { start = windowStart; prefix = "…" }
            if end - start > maxLength { end = start + maxLength; suffix = "…" }
            // 别把代理对劈成两半
            if start < units.count, UTF16.isTrailSurrogate(units[start]) { start += 1 }
            if end > start, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        }
        let body = String(decoding: units[start..<end], as: UTF16.self).replacingOccurrences(of: "\t", with: " ")
        let shift = prefix.utf16.count - start
        let ranges = line.ranges.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, start), upper = min(range.upperBound, end)
            return lower < upper ? (lower + shift)..<(upper + shift) : nil
        }
        return TextSearchSnippet(text: prefix + body + suffix, ranges: ranges)
    }
}

/// 不在 git 仓库里：逐个读文件搜。跳过二进制和超过 `fileSizeLimit` 的（压缩过的 bundle、数据文件，搜了也没法看）。
public enum TextSearchScanner {
    public static let fileSizeLimit = 2 * 1024 * 1024
    /// 不在 git 仓库里时没有 .gitignore 可依，这些目录照常理是生成物 / 依赖，不进去。
    public static let skippedDirectoryNames: Set<String> = ["node_modules"]

    /// 列文件时要不要跳过这个目录：隐藏目录（`.build`、`.venv`、`.idea`……）与 `node_modules`。隐藏**文件**照搜（`.env`、`.gitignore`）。
    public static func skipsDirectory(_ relativePath: String) -> Bool {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return name.hasPrefix(".") || skippedDirectoryNames.contains(name)
    }

    public static func search(
        files: [String],
        root: URL,
        query: TextSearchQuery,
        matcher: TextSearchMatcher,
        limit: Int,
        shouldStop: () -> Bool = { false }
    ) -> TextSearchResult {
        var collector = TextSearchCollector(limit: limit)
        scan: for path in files.sorted() where query.matchesMask(path) {
            if shouldStop() { break }
            let url = root.appendingPathComponent(path)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= fileSizeLimit,
                  let data = try? Data(contentsOf: url),
                  case .text(let text, _, _) = TextFileLoader.decode(data) else { continue }
            var number = 0
            // 按 UTF-16 的 \n 拆：Swift 的 Character 把 \r\n 当成一个字素，按字符拆的话 CRLF 文件整个是一行
            for raw in text.components(separatedBy: "\n") {
                number += 1
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
                let ranges = matcher.ranges(in: line)
                guard let first = ranges.first else { continue }
                if !collector.add(path: path, line: TextSearchLine(line: number, text: line, ranges: ranges, column: first.lowerBound)) { break scan }
            }
        }
        return collector.result
    }
}

/// 文件掩码里的通配：`*` 不跨 `/`，`**` 跨，`?` 一个字符。
enum Glob {
    static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*" {
                    characters.removeFirst()
                    if characters.first == "/" {
                        characters.removeFirst()
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return path.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
