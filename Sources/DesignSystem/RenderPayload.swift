import Core
import Foundation

/// diff 的两种排法。放在 DesignSystem：它是渲染层的概念，render.js 认的就是这两个值。
public enum DiffViewMode: String, CaseIterable, Sendable {
    case sideBySide = "side"
    case unified

    public var label: String {
        switch self {
        case .sideBySide: return "并排"
        // unified diff：一列，删除行在上、新增行在下，就是 `git diff` 命令行那种格式
        case .unified: return "单列"
        }
    }
}

/// 送进 render.js 的内容。**这就是 Swift 侧的渲染契约**：键名只在这里出现一次，
/// 与 render.js 顶部注释一一对应；改一边必须改另一边（`DesignSystemTests` 会真渲染一遍核对）。
public struct RenderPayload: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case code(path: String, text: String, language: String?)
        case markdown(path: String, markdown: String, documentDirectory: URL, showsSource: Bool)
        case image(path: String, url: URL, sizeText: String)
        case diff(path: String, language: String?, diff: FileDiff, mode: DiffViewMode, emptyReason: String?)
        case message(title: String, detail: String)
    }

    public var content: Content
    /// 渲染完停在哪（切回标签时恢复）。
    public var scrollTop: Double
    /// 代码是否自动换行。
    public var wrap: Bool

    public init(_ content: Content, scrollTop: Double = 0, wrap: Bool = false) {
        self.content = content
        self.scrollTop = scrollTop
        self.wrap = wrap
    }

    public static func message(_ title: String, _ detail: String) -> RenderPayload {
        RenderPayload(.message(title: title, detail: detail))
    }
}

extension RenderPayload: Encodable {
    private enum Key: String, CodingKey {
        case kind, scrollTop, wrap, path, text, language, markdown, docDir, view, url, sizeText
        case mode, rows, binary, empty, added, removed, emptyReason, title, detail
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(scrollTop, forKey: .scrollTop)
        try container.encode(wrap, forKey: .wrap)
        switch content {
        case .code(let path, let text, let language):
            try container.encode("code", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(language, forKey: .language)
        case .markdown(let path, let markdown, let directory, let showsSource):
            try container.encode("markdown", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(markdown, forKey: .markdown)
            try container.encode(directory.absoluteString, forKey: .docDir)
            try container.encode(showsSource ? "source" : "preview", forKey: .view)
        case .image(let path, let url, let sizeText):
            try container.encode("image", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(url.absoluteString, forKey: .url)
            try container.encode(sizeText, forKey: .sizeText)
        case .diff(let path, let language, let diff, let mode, let emptyReason):
            try container.encode("diff", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(mode.rawValue, forKey: .mode)
            try container.encode(diff.isBinary, forKey: .binary)
            try container.encode(diff.isEmpty, forKey: .empty)
            try container.encode(diff.addedCount, forKey: .added)
            try container.encode(diff.removedCount, forKey: .removed)
            try container.encodeIfPresent(emptyReason, forKey: .emptyReason)
            switch mode {
            case .sideBySide: try container.encode(DiffLayout.sideBySide(diff), forKey: .rows)
            case .unified: try container.encode(DiffLayout.unified(diff), forKey: .rows)
            }
        case .message(let title, let detail):
            try container.encode("message", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(detail, forKey: .detail)
        }
    }
}
