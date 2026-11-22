import Foundation

public enum FileComparison {
    public enum Source: Sendable {
        case file(URL, draft: String?)
        case clipboard(String)
    }

    public enum Contents: Equatable, Sendable {
        case text(String, String)
        case binary(identical: Bool)
    }

    public enum Error: LocalizedError {
        case unavailable(String)
        case tooLarge(String)
        case binaryClipboard

        public var errorDescription: String? {
            switch self {
            case .unavailable(let name): return "无法读取「\(name)」"
            case .tooLarge(let name): return "「\(name)」超过 2 MB 的文本比较上限"
            case .binaryClipboard: return "二进制文件无法与剪贴板文本比较"
            }
        }
    }

    private static let limit = 2 * 1024 * 1024

    /// Comparisons use a snapshot so later edits cannot change what an open tab represents.
    public static func read(_ left: Source, _ right: Source) throws -> Contents {
        let lhs = try read(left), rhs = try read(right)
        if let a = lhs.text, let b = rhs.text { return .text(LineEnding.normalized(a), LineEnding.normalized(b)) }
        guard case .file = left, case .file = right else { throw Error.binaryClipboard }
        return .binary(identical: lhs.data == rhs.data)
    }

    private static func read(_ source: Source) throws -> (data: Data, text: String?) {
        switch source {
        case .clipboard(let text):
            guard text.utf8.count <= limit else { throw Error.tooLarge("剪贴板") }
            return (Data(text.utf8), text)
        case .file(let url, let draft):
            let name = url.lastPathComponent
            if let draft {
                guard draft.utf8.count <= limit else { throw Error.tooLarge(name) }
                return (Data(draft.utf8), draft)
            }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize else { throw Error.unavailable(name) }
            guard size <= limit else { throw Error.tooLarge(name) }
            guard let data = try? Data(contentsOf: url) else { throw Error.unavailable(name) }
            guard data.count <= limit else { throw Error.tooLarge(name) }
            switch FileCategory.forFile(named: name) {
            case .image, .pdf: return (data, nil)
            default:
                if case .text(let text, _, _) = TextFileLoader.decode(data) { return (data, text) }
                return (data, nil)
            }
        }
    }
}
