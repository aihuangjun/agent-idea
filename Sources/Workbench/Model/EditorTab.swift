import Core
import DesignSystem
import Foundation

/// 编辑区的一个标签。文件标签可以编辑（未保存的文本放在 `ProjectSession.drafts`，不在这里）；diff 标签只读。
struct EditorTab: Identifiable, Equatable {
    enum Kind: Equatable {
        case file(URL)
        /// 工作区相对 HEAD 的变更。
        case diff(GitChange)
        /// 某次历史提交里一个文件的变更。
        case commitDiff(GitCommit, GitChange)
    }

    let id: String
    let kind: Kind
    /// IDEA 的「预览标签」：变更列表单击、Markdown 链接打开的内容占用同一个标签，双击才固定下来。
    var isPreview: Bool
    /// 切走时记下的滚动位置，切回来恢复。
    var scrollTop: Double = 0
    /// 切走时记下的光标位置（只有编辑器才有）。
    var cursor: EditorCursor?
    /// 切走时记下的编辑器撤销历史（CodeMirror `getHistory()` 的 JSON 文本）连同它对应的那份文本的哈希：
    /// 只有重画时的文本与记历史时的一模一样才装回去（`history(matching:)`）——同一文档的另一个标签改过、重命名重读、
    /// 磁盘上被别人改过之后，历史里的位置都对不上新内容，CodeMirror 的 `setHistory` 不校验，装回去 ⌘Z 会撕坏正文。
    var history: EditorHistory?

    /// 要画的文本就是记历史时的那份才给历史，否则从头记。
    func history(matching text: String) -> String? {
        guard let history, history.textHash == EditorHistory.hash(text) else { return nil }
        return history.json
    }
    /// Markdown 标签：看渲染结果、看源码，还是分栏。
    var markdownView: MarkdownView = .preview

    init(kind: Kind, isPreview: Bool) {
        self.kind = kind
        self.isPreview = isPreview
        switch kind {
        case .file(let url): id = Self.id(forFile: url)
        case .diff(let change): id = Self.id(forDiff: change)
        case .commitDiff(let commit, let change): id = Self.id(forCommit: commit, change: change)
        }
    }

    /// 标签 id 的拼法只在这几处：别处要按内容找标签时用它们，不要临时构造一个 EditorTab。
    /// 文件标签的 id 同时也是「文档 id」：diff 标签编辑的文件与文件标签共用同一份内容、基线、草稿。
    static func id(forFile url: URL) -> String { "file:" + url.path }
    /// 从文档 id 反推文件 URL。
    static func fileURL(fromID id: String) -> URL? {
        guard id.hasPrefix("file:") else { return nil }
        return URL(fileURLWithPath: String(id.dropFirst(5)))
    }
    static func id(forDiff change: GitChange) -> String { "diff:" + change.path }
    static func id(forCommit commit: GitCommit, change: GitChange) -> String { "commit:" + commit.hash + ":" + change.path }

    var title: String {
        switch kind {
        case .file(let url): return url.lastPathComponent
        case .diff(let change), .commitDiff(_, let change): return change.fileName
        }
    }

    var fileURL: URL? {
        if case .file(let url) = kind { return url }
        return nil
    }

    /// **工作区**的变更。git 状态刷新后要据此关掉已消失的 diff 标签，历史提交的 diff 不在其列。
    var change: GitChange? {
        if case .diff(let change) = kind { return change }
        return nil
    }

    /// 历史提交的 diff：哪次提交、哪个文件。
    var commitDiff: (commit: GitCommit, change: GitChange)? {
        if case .commitDiff(let commit, let change) = kind { return (commit, change) }
        return nil
    }

    /// 任一种 diff 标签对应的变更（面包屑、定位文件、渲染路径用）。
    var diffChange: GitChange? {
        switch kind {
        case .file: return nil
        case .diff(let change), .commitDiff(_, let change): return change
        }
    }

    var isDiff: Bool { diffChange != nil }
}

/// 一个标签里装的内容，加载完成后放进 `ProjectSession.contents`。
enum TabContent: Equatable {
    case loading
    case code(text: String, language: Language, encoding: String, lineCount: Int, modified: Date?)
    case markdown(text: String, encoding: String, lineCount: Int, modified: Date?)
    case image(url: URL, sizeBytes: Int)
    case binary(sizeBytes: Int)
    case tooLarge(sizeBytes: Int, limit: Int)
    case diff(FileDiff, language: Language)
    /// 可编辑的工作区 diff：两份全文由编辑器自己比。文件本身的内容在 `contents[documentID]`（与文件标签共用）。
    case editableDiff(documentID: String)
    case message(title: String, detail: String)

    /// 状态栏右侧那几格。
    var statusSummary: [String] {
        switch self {
        case .code(_, let language, let encoding, let lineCount, _):
            return ["\(lineCount) 行", encoding, language.name]
        case .markdown(_, let encoding, let lineCount, _):
            return ["\(lineCount) 行", encoding, "Markdown"]
        case .image(_, let size):
            return [Self.byteCount(size), "图片"]
        case .binary(let size):
            return [Self.byteCount(size), "二进制"]
        case .diff(let diff, let language):
            return diff.isBinary ? ["二进制"] : ["+\(diff.addedCount) −\(diff.removedCount)", language.name]
        default:
            return []
        }
    }

    var modificationDate: Date? {
        switch self {
        case .code(_, _, _, _, let modified), .markdown(_, _, _, let modified): return modified
        default: return nil
        }
    }

    /// 文本内容（代码 / Markdown）；其它种类为 nil。
    var text: String? {
        switch self {
        case .code(let text, _, _, _, _), .markdown(let text, _, _, _): return text
        default: return nil
        }
    }

    /// 读进来时用的编码名，保存时按它编回去。
    var encodingName: String? {
        switch self {
        case .code(_, _, let encoding, _, _), .markdown(_, let encoding, _, _): return encoding
        default: return nil
        }
    }

    /// 保存之后：同一份内容换上新文本与磁盘上的修改时间。
    func replacingText(_ text: String, modified: Date?) -> TabContent {
        let lines = TextFileLoader.lineCount(of: text)
        switch self {
        case .code(_, let language, let encoding, _, _): return .code(text: text, language: language, encoding: encoding, lineCount: lines, modified: modified)
        case .markdown(_, let encoding, _, _): return .markdown(text: text, encoding: encoding, lineCount: lines, modified: modified)
        default: return self
        }
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 左侧工具窗口。
enum ToolWindow: String {
    case project
    case commit
    case history
}

extension ChangeKind {
    /// 变更列表右侧的状态字。
    var label: String {
        switch self {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        case .renamed: return "重命名"
        case .conflicted: return "冲突"
        case .untracked: return "未跟踪"
        }
    }
}

/// 编辑器的撤销历史与它对应的文本（哈希）。
struct EditorHistory: Equatable {
    let json: String
    let textHash: Int

    init(json: String, text: String) {
        self.json = json
        textHash = Self.hash(text)
    }

    static func hash(_ text: String) -> Int { text.hashValue }
}
