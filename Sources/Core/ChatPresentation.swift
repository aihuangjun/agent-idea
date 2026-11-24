import Foundation

// KBReader Sources/AIChat/Core/ChatTranscript.swift: drawer sizing and Markdown blocks.
public enum ChatPanelLayout {
    public static let defaultWidth: Double = 380
    public static let minimumWidth: Double = 280

    public static func maximumWidth(windowWidth: Double) -> Double {
        max(windowWidth / 3, 0)
    }

    /// 窗口窄到 1/3 都不够最小宽度时，**上限说了算**：用户要的是「最大 1/3」，不是「最小 280」。
    public static func clamp(_ width: Double, windowWidth: Double) -> Double {
        let upper = maximumWidth(windowWidth: windowWidth)
        let lower = min(minimumWidth, upper)
        return min(max(width, lower), upper)
    }

    public static func range(windowWidth: Double) -> ClosedRange<Double> {
        let upper = maximumWidth(windowWidth: windowWidth)
        return min(minimumWidth, upper)...upper
    }
}

/// 回答正文切成「普通段落」与「代码块」：代码块要等宽、可横向滚动，普通段落走行内 Markdown。
public enum ChatMarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String, body: String)
    /// GFM 表格（表头一行 + `|---|` 分隔行 + 数据行）。行内 Markdown 认不得它，
    /// 原样画出来是一堆竖线（实测），要单独画成网格。
    case table(header: [String], rows: [[String]])
    /// `>` 引用块，画成左边一道竖线的灰字。
    case quote(String)

    /// 普通段落交给 SwiftUI 的行内 Markdown 之前，把它不认的块级写法换成看得懂的样子：
    /// 标题行 `## 标题` → 加粗；列表项 `- x` / `* x` → `• x`（缩进保留）。
    /// 不处理的话，回答里的每个小标题都带着一串 `#` 显示出来。
    public static func inlineFriendly(_ prose: String) -> String {
        prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " }
            let body = line.dropFirst(indent.count)
            if body.hasPrefix("#") {
                let hashes = body.prefix { $0 == "#" }
                let title = body.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                if hashes.count <= 6, body.dropFirst(hashes.count).first == " ", !title.isEmpty {
                    // `## **标题**` 本来就加粗了，再包一层成了 `****标题****`，解析器认不出来。
                    let bare = title.hasPrefix("**") && title.hasSuffix("**") && title.count > 4
                    return bare ? title : "**\(title)**"
                }
            }
            if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                return String(indent) + "• " + String(body.dropFirst(2))
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// 一行里的 `**加粗**` 自己配对，交出（片段, 是否加粗）。配不成对（奇数个）、或行里有行内代码时返回 nil，
    /// 交回给标准解析。
    ///
    /// **为什么不全交给 `AttributedString(markdown:)`**：CommonMark 判「能不能收尾」看两边的字符类别，
    /// 中文里常见的 `**执行边界：**先核对`、`“对象名称”**就可以**` 这种——收尾的 `**` 前面是标点、
    /// 后面紧跟汉字——按规则**不算收尾**，于是 `**` 原样露出来、加粗一路延到下一个 `**`（用户验收截图里的乱象）。
    /// 模型写中文时几乎必然这样写，只能自己配对。
    public static func strongSegments(_ line: String) -> [(text: String, strong: Bool)]? {
        guard line.contains("**"), !line.contains("`") else { return nil }
        let parts = line.components(separatedBy: "**")
        guard parts.count >= 3, parts.count % 2 == 1 else { return nil }
        return parts.enumerated().compactMap { index, part in
            part.isEmpty ? nil : (part, index % 2 == 1)
        }
    }

    public static func split(_ text: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language = ""
        var fence: String?
        func flushProse() {
            blocks += structured(prose)
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.trimmingCharacters(in: CharacterSet(charactersIn: String(open.prefix(1)) + " ")).isEmpty {
                    blocks.append(.code(language: language, body: code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let marker = trimmed.hasPrefix("```") ? "`" : "~"
                let run = trimmed.prefix { String($0) == marker }
                fence = String(run)
                language = String(trimmed.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
            } else {
                prose.append(line)
            }
        }
        // 流式输出到一半时围栏还没合上：剩下的照样当代码画，别在合上的那一刻整段跳版。
        if fence != nil { blocks.append(.code(language: language, body: code.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    /// 围栏之外的一段再细分：表格、引用单独成块，其余照旧是段落。
    /// 流式时表格只到了表头、分隔行还没来，就先当段落——分隔行一到整块变成表格。
    static func structured(_ lines: [Substring]) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var prose: [Substring] = []
        func flush() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    // 列数对齐表头：少的补空、多的并进最后一格，网格才不会错位。
                    var values = cells(row)
                    if values.count < header.count { values += Array(repeating: "", count: header.count - values.count) }
                    if values.count > header.count, !header.isEmpty {
                        values = Array(values.prefix(header.count - 1)) + [values.dropFirst(header.count - 1).joined(separator: " | ")]
                    }
                    rows.append(values)
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    var body = line.dropFirst()
                    if body.first == " " { body = body.dropFirst() }
                    quoted.append(String(body))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            prose.append(lines[index])
            index += 1
        }
        flush()
        return blocks
    }

    /// `|---|:--:|` 这样的分隔行：至少一格，每格是可带冒号的三个以上横线（GFM 允许一个，放宽到一个）。
    static func isTableSeparator(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let parts = cells(trimmed)
        return !parts.isEmpty && parts.allSatisfy { part in
            let core = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    /// `| a | b |` → ["a", "b"]。两端的竖线可有可无；`\|` 是格子里的竖线，不切。
    static func cells(_ row: String) -> [String] {
        var body = Substring(row.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped { current.append(character == "|" ? "|" : "\\\(character)"); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
}
