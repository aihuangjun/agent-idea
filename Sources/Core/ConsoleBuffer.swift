import Foundation

/// 「运行」窗口里的输出：一段一段往后接，标着是标准输出、标准错误还是我们自己说的话。
///
/// 视图只往后追加新的段（`segments[已画过的个数...]`），不每次重画全部；清空或掐掉开头时 `generation` 变一下，视图整个重来。
/// 段只追加、不改，视图才能按个数接着画。
public struct ConsoleBuffer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case output
        case error
        /// 我们自己打的：开头那行命令、结尾的退出码、找不到程序的说明。
        case system
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let kind: Kind
    }

    public private(set) var segments: [Segment] = []
    /// 清空、掐掉开头时加一：视图看到它变了就整个重画。
    public private(set) var generation = 0
    /// 因为超过上限从开头丢掉的行数。
    public private(set) var droppedLines = 0
    public private(set) var lineCount = 0
    /// 最多留多少行：超了从开头丢到 `lineLimit * 4/5`（一次丢一批，免得每来一行都整个重画）。
    public let lineLimit: Int

    public init(lineLimit: Int = 20_000) {
        self.lineLimit = max(lineLimit, 10)
    }

    public var isEmpty: Bool { segments.isEmpty }
    public var text: String { segments.map(\.text).joined() }

    public mutating func append(_ text: String, kind: Kind) {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return }
        segments.append(Segment(text: cleaned, kind: kind))
        lineCount += cleaned.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if lineCount > lineLimit { trim() }
    }

    public mutating func clear() {
        segments = []
        lineCount = 0
        droppedLines = 0
        generation += 1
    }

    private mutating func trim() {
        // 上次留下的「已省略」提示不算在 lineCount 里，先拿掉，丢完再放一条新的
        if segments.first?.kind == .system, segments.first?.text.hasPrefix(Self.noticePrefix) == true { segments.removeFirst() }
        var excess = lineCount - lineLimit * 4 / 5
        var dropped = 0
        while excess > 0, let first = segments.first {
            let lines = first.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            if lines <= excess {
                segments.removeFirst()
                excess -= lines
                dropped += lines
            } else {
                // 只丢这一段开头的几行
                var remaining = excess
                let index = first.text.firstIndex { character in
                    guard character == "\n" else { return false }
                    remaining -= 1
                    return remaining == 0
                }.map { first.text.index(after: $0) } ?? first.text.endIndex
                segments[0] = Segment(text: String(first.text[index...]), kind: first.kind)
                dropped += excess
                excess = 0
            }
        }
        lineCount -= dropped
        droppedLines += dropped
        segments.insert(Segment(text: "\(Self.noticePrefix)\(droppedLines) 行已省略…\n", kind: .system), at: 0)
        generation += 1
    }

    private static let noticePrefix = "…前面 "

    /// 去掉 ANSI 控制序列（颜色、清行）；`\r\n` 归一成 `\n`，单独的 `\r`（进度条回到行首重画）也当换行。
    /// 不是终端时大多数工具本来就不着色，这里只是保险。
    static func clean(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.contains("\r") else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar {
            case "\u{1B}":
                // CSI：ESC [ 参数… 结尾字节（0x40–0x7E）；OSC：ESC ] … BEL 或 ESC \；其余 ESC + 一个字符
                if pending == "[" {
                    pending = scalars.next()
                    while let next = pending, !(0x40...0x7E).contains(next.value) { pending = scalars.next() }
                    pending = scalars.next()
                } else if pending == "]" {
                    pending = scalars.next()
                    while let next = pending, next != "\u{07}", next != "\u{1B}" { pending = scalars.next() }
                    if pending == "\u{1B}" { pending = scalars.next() }
                    pending = scalars.next()
                } else {
                    pending = scalars.next()
                }
            case "\r":
                if pending == "\n" { pending = scalars.next() }
                result.unicodeScalars.append("\n")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// 管子里来的字节块可能把一个多字节字符切在两块之间：末尾不完整的那几个字节先留着，跟下一块拼起来再解。
public struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(data)
        let cut = Self.completePrefixLength(bytes)
        pending = bytes.subdata(in: cut..<bytes.count)
        return String(decoding: bytes.prefix(cut), as: UTF8.self)
    }

    /// 流结束：剩下的不完整字节照原样解（会变成替换字符），不吞掉。
    public mutating func finish() -> String {
        defer { pending = Data() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    /// 末尾最多 3 个字节可能是半个字符：找到最后一个起始字节，看它要的长度够不够。
    static func completePrefixLength(_ bytes: Data) -> Int {
        let count = bytes.count
        let start = bytes.startIndex
        var back = 0
        while back < min(3, count) {
            let byte = bytes[start + count - 1 - back]
            if byte & 0xC0 != 0x80 {
                // 起始字节（或 ASCII）：它要几个字节
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return back + 1 >= needed ? count : count - 1 - back
            }
            back += 1
        }
        return count
    }
}
