import Foundation

/// 一个文件读出来是什么。
public enum LoadedContent: Equatable, Sendable {
    /// 文本，附带用的是哪种编码（给状态栏显示）与行数。
    case text(String, encoding: String, lineCount: Int)
    case binary(sizeBytes: Int)
    case tooLarge(sizeBytes: Int, limit: Int)
    case unreadable(String)
}

/// 读文本文件并猜编码。
///
/// 顺序：UTF-8 → 带 BOM 的 UTF-16 → GB18030（中文环境下老文件常见）→ Latin-1 兜底。
/// 前 8KB 里出现 NUL 且不是 UTF-16 BOM 开头的，判为二进制。
public enum TextFileLoader {
    /// 默认读取上限。超过的文件不是这个阅读器该打开的东西（日志、数据集）。
    public static let defaultLimit = 8 << 20

    public static func load(_ url: URL, limit: Int = defaultLimit, fileManager: FileManager = .default) -> LoadedContent {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > limit { return .tooLarge(sizeBytes: size, limit: limit) }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable("读不出这个文件：\(url.lastPathComponent)")
        }
        return decode(data)
    }

    public static func decode(_ data: Data) -> LoadedContent {
        if data.isEmpty { return .text("", encoding: "UTF-8", lineCount: 0) }

        let head = data.prefix(8192)
        let hasUTF16BOM = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        if !hasUTF16BOM, head.contains(0) {
            return .binary(sizeBytes: data.count)
        }

        if let text = String(data: data, encoding: .utf8) {
            return .text(text, encoding: "UTF-8", lineCount: lineCount(of: text))
        }
        if hasUTF16BOM, let text = String(data: data, encoding: .utf16) {
            return .text(text, encoding: "UTF-16", lineCount: lineCount(of: text))
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        if let text = String(data: data, encoding: gb18030) {
            return .text(text, encoding: "GB18030", lineCount: lineCount(of: text))
        }
        let text = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        return .text(text, encoding: "Latin-1", lineCount: lineCount(of: text))
    }

    /// 行数按「有多少行可以显示」算：末尾的换行不多算一行，空文件是 0 行。
    public static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        text.enumerateLines { _, _ in count += 1 }
        return count
    }
}
