import Core
import Foundation

/// 编辑区的一个标签。**只读**——这个应用不编辑文件。
struct EditorTab: Identifiable, Equatable {
    enum Kind: Equatable {
        case file(URL)
        case diff(GitChange)
    }

    let id: String
    let kind: Kind
    /// IDEA 的「预览标签」：变更列表单击、Markdown 链接打开的内容占用同一个标签，双击才固定下来。
    var isPreview: Bool
    /// 切走时记下的滚动位置，切回来恢复。
    var scrollTop: Double = 0
    /// Markdown 标签：看渲染结果还是看源码。
    var markdownShowsSource = false

    init(kind: Kind, isPreview: Bool) {
        self.kind = kind
        self.isPreview = isPreview
        switch kind {
        case .file(let url): id = Self.id(forFile: url)
        case .diff(let change): id = Self.id(forDiff: change)
        }
    }

    /// 标签 id 的拼法只在这两处：别处要按内容找标签时用它们，不要临时构造一个 EditorTab。
    static func id(forFile url: URL) -> String { "file:" + url.path }
    static func id(forDiff change: GitChange) -> String { "diff:" + change.path }

    var title: String {
        switch kind {
        case .file(let url): return url.lastPathComponent
        case .diff(let change): return change.fileName
        }
    }

    var fileURL: URL? {
        if case .file(let url) = kind { return url }
        return nil
    }

    var change: GitChange? {
        if case .diff(let change) = kind { return change }
        return nil
    }

    var isDiff: Bool { change != nil }
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

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 左侧工具窗口。
enum ToolWindow: String {
    case project
    case commit
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
