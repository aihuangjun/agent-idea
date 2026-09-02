import Core
import Foundation

/// 编辑区的一个标签。**只读**——这个应用不编辑文件。
public struct EditorTab: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file(URL)
        case diff(GitChange)
    }

    public let id: String
    public let kind: Kind
    /// IDEA 的「预览标签」：单击打开的文件占用同一个标签，双击才固定下来。
    /// 不这样的话，在目录树里逐个点文件看一圈，标签栏就爆了。
    public var isPreview: Bool
    /// 切走时记下的滚动位置，切回来恢复。
    public var scrollTop: Double = 0
    /// Markdown 标签：看渲染结果还是看源码。
    public var markdownShowsSource = false

    public init(kind: Kind, isPreview: Bool) {
        self.kind = kind
        self.isPreview = isPreview
        switch kind {
        case .file(let url): id = "file:" + url.path
        case .diff(let change): id = "diff:" + change.path
        }
    }

    public var title: String {
        switch kind {
        case .file(let url): return url.lastPathComponent
        case .diff(let change): return change.fileName
        }
    }

    public var fileURL: URL? {
        if case .file(let url) = kind { return url }
        return nil
    }

    public var change: GitChange? {
        if case .diff(let change) = kind { return change }
        return nil
    }

    public var isDiff: Bool { change != nil }
}

/// 一个标签里装的内容，加载完成后放进 `WorkspaceModel.contents`。
public enum TabContent: Equatable, Sendable {
    case loading
    case code(text: String, language: Language, encoding: String, lineCount: Int, modified: Date?)
    case markdown(text: String, encoding: String, lineCount: Int, modified: Date?)
    case image(url: URL, sizeBytes: Int)
    case binary(sizeBytes: Int)
    case tooLarge(sizeBytes: Int, limit: Int)
    case diff(FileDiff, language: Language)
    case message(title: String, detail: String)

    /// 状态栏右侧那几格。
    public var statusSummary: [String] {
        switch self {
        case .code(_, let language, let encoding, let lineCount, _):
            return ["\(lineCount) 行", encoding, language.name]
        case .markdown(_, let encoding, let lineCount, _):
            return ["\(lineCount) 行", encoding, "Markdown"]
        case .image(_, let size):
            return [ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), "图片"]
        case .binary(let size):
            return [ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), "二进制"]
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
}

public enum DiffMode: String, CaseIterable, Sendable {
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

/// 左侧工具窗口。
public enum ToolWindow: String, Sendable {
    case project
    case commit
}
