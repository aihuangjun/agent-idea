import Foundation

/// A user-selected item exposed through the chat's read tools, independently of its project.
public struct AIChatReference: Identifiable, Sendable {
    public let id: Int
    public let url: URL
    public let isDirectory: Bool
    private let scope: AIWorkspace

    public var name: String { url.lastPathComponent }
    public var toolPath: String { "reference://\(id)" }
    public var manifestEntry: String {
        "\(toolPath) — \(isDirectory ? "目录" : "文件") \(String(reflecting: name))"
    }

    public init(id: Int, url: URL) throws {
        guard url.isFileURL else { throw AIWorkspace.Problem.unsafePath }
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true, info.isDirectory == true || info.isRegularFile == true else {
            throw AIWorkspace.Problem.unsupportedFile
        }
        self.id = id
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        isDirectory = info.isDirectory == true
        let root = isDirectory ? self.url : self.url.deletingLastPathComponent()
        scope = try AIWorkspace(root: root, singleFileParent: !isDirectory)
        if !isDirectory { _ = try scope.fileURL(for: self.url.lastPathComponent) }
    }

    public static func handles(_ path: String) -> Bool { path.hasPrefix("reference://") }

    public static func invoke(_ request: AIWorkspaceTool.Request, references: [Self]) throws -> AIWorkspaceTool.Result {
        try Task.checkCancellation()
        guard let reference = references.first(where: { request.path == $0.toolPath || request.path.hasPrefix($0.toolPath + "/") }) else {
            throw AIWorkspace.Problem.notFound
        }
        let path = request.path == reference.toolPath ? "" : String(request.path.dropFirst(reference.toolPath.count + 1))
        switch request {
        case .list where reference.isDirectory:
            let entries = try reference.scope.list(path)
            return .init(summary: "列出 \(entries.count) 项", output: entries.isEmpty ? "目录为空" : entries.joined(separator: "\n"))
        case .read(_, let start, let count) where reference.isDirectory || path.isEmpty:
            let text = try reference.scope.read(reference.isDirectory ? path : reference.name, startLine: start, lineCount: count)
            return .init(summary: "已读取引用文件", output: text)
        case .search(_, let query) where reference.isDirectory:
            let result = try reference.scope.search(query, under: path)
            return .init(summary: "已搜索引用目录", output: result)
        case .replace, .create:
            throw ReferenceError.readOnly
        default:
            throw AIWorkspace.Problem.unsafePath
        }
    }

    private enum ReferenceError: LocalizedError {
        case readOnly
        var errorDescription: String? { "聊天引用仅供读取" }
    }
}
