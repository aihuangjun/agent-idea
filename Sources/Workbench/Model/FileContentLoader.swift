import Core
import DesignSystem
import Foundation

/// 把磁盘上的文件 / git 的 diff 变成 `TabContent`，再把 `TabContent` 变成渲染契约。
/// 纯函数，都是有分支的逻辑，配单测。
enum FileContentLoader {
    nonisolated static func load(_ url: URL, fileManager: FileManager) -> TabContent {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard fileManager.fileExists(atPath: url.path) else {
            return .message(title: "文件不存在", detail: url.path)
        }
        switch FileCategory.forFile(named: url.lastPathComponent) {
        case .image:
            return .image(url: url, sizeBytes: size)
        case .pdf:
            return .message(title: "PDF 暂不支持预览", detail: "用系统预览打开：右键标签 → 用默认应用打开")
        case .markdown:
            return text(TextFileLoader.load(url, fileManager: fileManager), name: url.lastPathComponent) {
                .markdown(text: $0, encoding: $1, lineCount: $2, modified: modified)
            }
        case .code(let language):
            return text(TextFileLoader.load(url, fileManager: fileManager), name: url.lastPathComponent) {
                .code(text: $0, language: language, encoding: $1, lineCount: $2, modified: modified)
            }
        }
    }

    private static func text(_ loaded: LoadedContent, name: String, make: (String, String, Int) -> TabContent) -> TabContent {
        switch loaded {
        case .text(let text, let encoding, let lines): return make(text, encoding, lines)
        case .binary(let size): return .binary(sizeBytes: size)
        case .tooLarge(let size, let limit): return .tooLarge(sizeBytes: size, limit: limit)
        case .unreadable: return .message(title: "读不出文件", detail: name)
        }
    }

    /// 工作区变更的 diff；`commit` 给了就是那次提交里这个文件的 diff。
    nonisolated static func loadDiff(_ change: GitChange, in commit: GitCommit? = nil, git: GitClient, repositoryRoot: URL) async -> TabContent {
        do {
            let raw: String
            if let commit {
                raw = try await git.diff(change: change, in: commit, repositoryRoot: repositoryRoot)
            } else {
                raw = try await git.diff(change: change, repositoryRoot: repositoryRoot)
            }
            return .diff(UnifiedDiffParser.parse(raw), language: Language.forFile(named: change.fileName))
        } catch {
            return .message(title: "取不到 diff", detail: error.userFacingDescription)
        }
    }

    /// 开着的内容与磁盘上的是否已经对不上。
    static func isStale(_ content: TabContent, modifiedOnDisk: Date?, exists: Bool) -> Bool {
        switch content {
        case .loading: return false
        // 之前显示「文件不存在」之类的提示，文件回来了就该重读
        case .message: return exists
        case .code, .markdown: return !exists || modifiedOnDisk != content.modificationDate
        default: return !exists || modifiedOnDisk != nil
        }
    }
}

extension TabContent {
    /// 这份内容在 WebView 里怎么画。
    func renderContent(for tab: EditorTab, diffMode: DiffViewMode) -> RenderPayload.Content {
        let path = tab.fileURL?.path ?? tab.diffChange?.path ?? ""
        switch self {
        case .loading:
            return .message(title: "", detail: "")
        case .code(let text, let language, _, _, _):
            return .code(path: path, text: text, language: language.highlightID)
        case .markdown(let text, _, _, _):
            return .markdown(
                path: path, markdown: text,
                documentDirectory: tab.fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"),
                showsSource: tab.markdownShowsSource
            )
        case .image(let url, let size):
            return .image(path: url.path, url: url, sizeText: Self.byteCount(size))
        case .binary(let size):
            return .message(title: "二进制文件", detail: "\(tab.title) · \(Self.byteCount(size))\n这个阅读器只显示文本。")
        case .tooLarge(let size, let limit):
            return .message(title: "文件太大", detail: "\(Self.byteCount(size))，超过 \(Self.byteCount(limit)) 的阅读上限。")
        case .diff(let diff, let language):
            let emptyReason = diff.isEmpty && tab.diffChange?.kind == .untracked ? "这是一个空文件。" : nil
            return .diff(path: path, language: language.highlightID, diff: diff, mode: diffMode, emptyReason: emptyReason)
        case .message(let title, let detail):
            return .message(title: title, detail: detail)
        }
    }
}
