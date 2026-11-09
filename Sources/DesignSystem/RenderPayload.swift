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

public enum HTMLView: String, CaseIterable, Sendable {
    case preview, source

    public var label: String { self == .preview ? "预览" : "源码" }
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

/// 全文 diff 的两份原文。工作区的右侧可编辑，历史版本及删除文件只读。
public struct DiffEdit: Equatable, Sendable {
    public var oldText: String
    public var newText: String
    /// 工作区文件的绝对路径：编辑器发 edited 消息、基线更新时都靠它对上文档。
    public var filePath: String
    public var cursor: EditorCursor?
    /// 编辑器的撤销历史（CodeMirror `getHistory()` 的 JSON 文本），切标签时带走再带回来，⌘Z 才能撤到切走之前。
    public var history: String?
    /// 历史版本及已删除文件也使用全文视图，但不产生 edited 消息。
    public var readOnly: Bool

    public init(oldText: String, newText: String, filePath: String, cursor: EditorCursor? = nil, history: String? = nil, readOnly: Bool = false) {
        self.oldText = oldText
        self.newText = newText
        self.filePath = filePath
        self.cursor = cursor
        self.history = history
        self.readOnly = readOnly
    }
}

/// 送进 render.js 的内容。**这就是 Swift 侧的渲染契约**：键名只在这里出现一次，
/// 与 render.js 顶部注释一一对应；改一边必须改另一边（`DesignSystemTests` 会真渲染一遍核对）。
public struct RenderPayload: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// `editable` 为真时用编辑器（CodeMirror）画，否则是只读的静态视图。`base` 是这个文件在 HEAD 里的内容，
        /// 编辑器据此在行号旁画「改过 / 新增」的标记；nil 表示没有基线（未跟踪、没有 git）。
        case code(path: String, text: String, language: String?, editable: Bool = false, cursor: EditorCursor? = nil, base: String? = nil, history: String? = nil)
        case markdown(path: String, markdown: String, documentDirectory: URL, view: MarkdownView, editable: Bool = false, cursor: EditorCursor? = nil, base: String? = nil, history: String? = nil)
        case image(path: String, url: URL, sizeText: String)
        /// 独立 WebView 中的 HTML 预览，与持有编辑桥的 shell 隔离；相对资源按原文件解析，读取范围由 documentDirectory 限定。
        case html(path: String, text: String, documentDirectory: URL)
        /// `edit` 非空时携带两侧全文与 Core 比较结果，支持上下文展开；readOnly 决定右侧能否编辑。
        /// 没有全文的二进制 / 大文件退回静态补丁。
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
    /// 首次打开或跨文件导航时的落点；nil 恢复标签原来的位置。
    public var revealChange: DiffEdge?
    /// 渲染完跳到哪一行（行列从 0 数，超出范围夹到首尾）：查找文件带了 `路径:行号`、跳到行时标签还没画出来。
    /// 编辑器把光标放过去，只读视图选中那一行，都把它滚到正中；diff 按新版本那一侧算。nil 不跳。
    public var revealLine: EditorCursor?
    public var diffReading: DiffReadingOptions
    /// 编辑器的阅读现场（JSON）：逻辑行、屏幕偏移和已展开区间，随标签往返。
    public var diffViewState: String?

    public init(_ content: Content, scrollTop: Double = 0, wrap: Bool = false, revealChange: DiffEdge? = nil, revealLine: EditorCursor? = nil,
                diffReading: DiffReadingOptions = DiffReadingOptions(), diffViewState: String? = nil) {
        self.content = content
        self.scrollTop = scrollTop
        self.wrap = wrap
        self.revealChange = revealChange
        self.revealLine = revealLine
        self.diffReading = diffReading
        self.diffViewState = diffViewState
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
        case .html: return "html"
        case .diff: return "diff"
        case .message: return "message"
        }
    }
}

extension RenderPayload: Encodable {
    /// 编辑后的增量消息也复用 payload 的键名，保持 Swift 渲染契约只有一处声明。
    struct DiffReviewUpdate: Encodable {
        let path: String
        let newText: String
        let analysis: DiffReviewAnalysis
        let baseIdentity: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(path, forKey: .path)
            try container.encode(newText, forKey: .newText)
            try container.encode(analysis, forKey: .analysis)
            try container.encode(baseIdentity, forKey: .baseIdentity)
        }
    }

    private enum Key: String, CodingKey {
        case kind, scrollTop, wrap, revealChange, revealLine, path, text, language, editable, cursor, base, history, markdown, docDir, view, url, sizeText
        case mode, rows, binary, empty, added, removed, emptyReason, title, detail, edit, oldText, newText, filePath
        case diffReading, analysis, readOnly, diffViewState, baseIdentity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(scrollTop, forKey: .scrollTop)
        try container.encode(wrap, forKey: .wrap)
        try container.encodeIfPresent(revealChange, forKey: .revealChange)
        try container.encodeIfPresent(revealLine, forKey: .revealLine)
        switch content {
        case .code(let path, let text, let language, let editable, let cursor, let base, let history):
            try container.encode("code", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(editable, forKey: .editable)
            try container.encodeIfPresent(cursor, forKey: .cursor)
            try container.encodeIfPresent(base, forKey: .base)
            try container.encodeIfPresent(history, forKey: .history)
        case .markdown(let path, let markdown, let directory, let view, let editable, let cursor, let base, let history):
            try container.encode("markdown", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(markdown, forKey: .markdown)
            try container.encode(directory.absoluteString, forKey: .docDir)
            try container.encode(view.rawValue, forKey: .view)
            try container.encode(editable, forKey: .editable)
            try container.encodeIfPresent(cursor, forKey: .cursor)
            try container.encodeIfPresent(base, forKey: .base)
            try container.encodeIfPresent(history, forKey: .history)
        case .image(let path, let url, let sizeText):
            try container.encode("image", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(url.absoluteString, forKey: .url)
            try container.encode(sizeText, forKey: .sizeText)
        case .html(let path, let text, let directory):
            try container.encode("html", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encode(directory.absoluteString, forKey: .docDir)
        case .diff(let path, let language, let diff, let mode, let emptyReason, let edit):
            try container.encode("diff", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(mode.rawValue, forKey: .mode)
            if let edit {
                try container.encodeIfPresent(diffViewState, forKey: .diffViewState)
                try container.encode(diffReading, forKey: .diffReading)
                try container.encode(DiffReviewAnalysis(oldText: edit.oldText, newText: edit.newText, options: diffReading), forKey: .analysis)
                var editContainer = container.nestedContainer(keyedBy: Key.self, forKey: .edit)
                try editContainer.encode(edit.oldText, forKey: .oldText)
                // 现场只在当前进程内恢复；基线变化后不能沿用旧的展开区间。
                try editContainer.encode(String(edit.oldText.hashValue), forKey: .baseIdentity)
                try editContainer.encode(edit.newText, forKey: .newText)
                try editContainer.encode(edit.filePath, forKey: .filePath)
                try editContainer.encodeIfPresent(edit.cursor, forKey: .cursor)
                try editContainer.encodeIfPresent(edit.history, forKey: .history)
                try editContainer.encode(edit.readOnly, forKey: .readOnly)
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
