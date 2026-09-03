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

/// Markdown 标签的三种看法。render.js 认的就是这三个值。
public enum MarkdownView: String, CaseIterable, Sendable {
    case preview
    case source
    /// 左边编辑源码、右边实时预览（IDEA 的默认）。
    case split

    public var label: String {
        switch self {
        case .preview: return "预览"
        case .source: return "源码"
        case .split: return "分栏"
        }
    }

    public var next: MarkdownView {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// 编辑器里的光标位置（CodeMirror 的 {line, ch}，都从 0 数）。切标签时记下，切回来恢复。
public struct EditorCursor: Equatable, Sendable, Codable {
    public var line: Int
    public var ch: Int

    public init(line: Int, ch: Int) {
        self.line = line
        self.ch = ch
    }
}

/// 可编辑 diff 的两份文本：左边是基线（HEAD），右边是工作区里的（含未保存的草稿），编辑器改的是右边。
public struct DiffEdit: Equatable, Sendable {
    public var oldText: String
    public var newText: String
    /// 工作区文件的绝对路径：编辑器发 edited 消息、基线更新时都靠它对上文档。
    public var filePath: String
    public var cursor: EditorCursor?

    public init(oldText: String, newText: String, filePath: String, cursor: EditorCursor? = nil) {
        self.oldText = oldText
        self.newText = newText
        self.filePath = filePath
        self.cursor = cursor
    }
}

/// 送进 render.js 的内容。**这就是 Swift 侧的渲染契约**：键名只在这里出现一次，
/// 与 render.js 顶部注释一一对应；改一边必须改另一边（`DesignSystemTests` 会真渲染一遍核对）。
public struct RenderPayload: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// `editable` 为真时用编辑器（CodeMirror）画，否则是只读的静态视图。`base` 是这个文件在 HEAD 里的内容，
        /// 编辑器据此在行号旁画「改过 / 新增」的标记；nil 表示没有基线（未跟踪、没有 git）。
        case code(path: String, text: String, language: String?, editable: Bool = false, cursor: EditorCursor? = nil, base: String? = nil)
        case markdown(path: String, markdown: String, documentDirectory: URL, view: MarkdownView, editable: Bool = false, cursor: EditorCursor? = nil, base: String? = nil)
        case image(path: String, url: URL, sizeText: String)
        /// `edit` 非空时是可编辑的 diff（工作区变更）：不送 rows，两份全文由编辑器自己比；否则是只读的静态表格。
        case diff(path: String, language: String?, diff: FileDiff, mode: DiffViewMode, emptyReason: String?, edit: DiffEdit? = nil)
        case message(title: String, detail: String)
    }

    public var content: Content
    /// 日志里用的种类名。
    public var kindName: String { content.kindName }
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

public extension RenderPayload.Content {
    var kindName: String {
        switch self {
        case .code: return "code"
        case .markdown: return "markdown"
        case .image: return "image"
        case .diff: return "diff"
        case .message: return "message"
        }
    }
}

extension RenderPayload: Encodable {
    private enum Key: String, CodingKey {
        case kind, scrollTop, wrap, path, text, language, editable, cursor, base, markdown, docDir, view, url, sizeText
        case mode, rows, binary, empty, added, removed, emptyReason, title, detail, edit, oldText, newText, filePath
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(scrollTop, forKey: .scrollTop)
        try container.encode(wrap, forKey: .wrap)
        switch content {
        case .code(let path, let text, let language, let editable, let cursor, let base):
            try container.encode("code", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(editable, forKey: .editable)
            try container.encodeIfPresent(cursor, forKey: .cursor)
            try container.encodeIfPresent(base, forKey: .base)
        case .markdown(let path, let markdown, let directory, let view, let editable, let cursor, let base):
            try container.encode("markdown", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(markdown, forKey: .markdown)
            try container.encode(directory.absoluteString, forKey: .docDir)
            try container.encode(view.rawValue, forKey: .view)
            try container.encode(editable, forKey: .editable)
            try container.encodeIfPresent(cursor, forKey: .cursor)
            try container.encodeIfPresent(base, forKey: .base)
        case .image(let path, let url, let sizeText):
            try container.encode("image", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(url.absoluteString, forKey: .url)
            try container.encode(sizeText, forKey: .sizeText)
        case .diff(let path, let language, let diff, let mode, let emptyReason, let edit):
            try container.encode("diff", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(mode.rawValue, forKey: .mode)
            if let edit {
                var editContainer = container.nestedContainer(keyedBy: Key.self, forKey: .edit)
                try editContainer.encode(edit.oldText, forKey: .oldText)
                try editContainer.encode(edit.newText, forKey: .newText)
                try editContainer.encode(edit.filePath, forKey: .filePath)
                try editContainer.encodeIfPresent(edit.cursor, forKey: .cursor)
                return
            }
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
