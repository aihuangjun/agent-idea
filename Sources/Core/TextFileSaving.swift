import Foundation

/// 文本文件的行尾风格。编辑器里一律用 `\n`，保存时还原成文件原来的样子，别给 git 留下整文件的行尾噪音。
public enum LineEnding: Equatable, Sendable {
    case lf
    case crlf

    /// 看第一个换行符是哪种。没有换行的按 LF。
    /// 按 UTF-8 字节扫：Swift 把 `\r\n` 当成一个字素，用 `Character` 找 `\n` 会找不到。
    public static func detect(in text: String) -> LineEnding {
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A { return previous == 0x0D ? .crlf : .lf }
            previous = byte
        }
        return .lf
    }

    /// 把编辑器给的（只有 `\n`）文本改成这种行尾。
    public func apply(to text: String) -> String {
        switch self {
        case .lf: return text
        case .crlf: return Self.normalized(text).replacingOccurrences(of: "\n", with: "\r\n")
        }
    }

    /// 统一成 `\n`（编辑器里的样子），比较「改没改」用。
    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}

/// 把编辑器里的文本写回磁盘：用文件原来的编码与行尾。
///
/// `TextFileLoader` 读的时候报出编码名（UTF-8 / UTF-16 / GB18030 / Latin-1），写的时候按同一个名字编回去；
/// 编不回去（GB18030 表示不了新输进去的字符）就退回 UTF-8。
public enum TextFileSaver {
    /// 编码名 → 编码。名字是 `TextFileLoader` 报出来的那几个。
    public static func encoding(named name: String) -> String.Encoding {
        switch name {
        case "UTF-16": return .utf16
        case "GB18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "Latin-1": return .isoLatin1
        default: return .utf8
        }
    }

    /// 要写进文件的字节。`original` 是读进来时的文本，用来判断行尾风格。
    public static func data(for text: String, encodingName: String, original: String) -> Data {
        let content = LineEnding.detect(in: original).apply(to: text)
        if let data = content.data(using: encoding(named: encodingName)) { return data }
        Log.warn("editor", "文本用 \(encodingName) 编不回去，改用 UTF-8 保存")
        return Data(content.utf8)
    }

    /// 原子写入（先写临时文件再换名），中途崩了不会留下半个文件。
    public static func write(_ text: String, to url: URL, encodingName: String, original: String) throws {
        try data(for: text, encodingName: encodingName, original: original).write(to: url, options: .atomic)
    }
}
