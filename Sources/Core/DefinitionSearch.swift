import Foundation

/// 项目内的定义查找。先按语言和标识符筛文件，再交给语法树找声明。
public enum DefinitionSearch {
    private static let languageExtensions: [Set<String>] = [
        ["java"], ["swift"], ["go"], ["py", "pyi", "pyw"],
        ["js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"],
        ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "ino"],
    ]
    private static let fileSizeLimit = TextSearchScanner.fileSizeLimit
    private static let inputBudget = 12 * 1024 * 1024

    public static func extensions(for url: URL) -> Set<String> {
        languageExtensions.first { $0.contains(url.pathExtension.lowercased()) } ?? []
    }

    public struct Source: Codable, Sendable {
        public let path: String
        public let text: String
    }

    public struct Input: Sendable {
        public let sources: [Source]
        public let truncated: Bool
    }

    /// Git 仓库用 NUL 分隔的路径列表；普通目录复用文件索引。草稿覆盖同一文件的磁盘文本。
    public static func input(
        name: String, preferredFileStem: String? = nil, source: URL, root: URL, git: GitClient?, drafts: [String: String],
        isExcluded: @escaping @Sendable (String, Bool) -> Bool
    ) async throws -> Input {
        let extensions = extensions(for: source)
        guard !extensions.isEmpty, !name.isEmpty else { return Input(sources: [], truncated: false) }
        let matches = try await git?.pathsContaining(symbol: name, extensions: extensions, in: root)
        let worker = Task.detached(priority: .userInitiated) {
            let paths = matches ?? FileIndexer.index(root: root, shouldStop: { Task.isCancelled }) { path, directory in
                isExcluded(path, directory) || (directory && TextSearchScanner.skipsDirectory(path))
            }.map(\.path)
            return read(paths: paths, name: name, preferredFileStem: preferredFileStem ?? name,
                        source: source, root: root, extensions: extensions, drafts: drafts)
        }
        return try await withTaskCancellationHandler {
            let result = await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    private static func read(
        paths: [String], name: String, preferredFileStem: String, source: URL, root: URL,
        extensions: Set<String>, drafts: [String: String]
    ) -> Input {
        var paths = Set(paths)
        for path in drafts.keys {
            if let relative = FileReference.relativePath(of: path, root: root.path) { paths.insert(relative) }
        }
        let currentDirectory = FileReference.relativePath(of: source.deletingLastPathComponent().path, root: root.path)
        let ordered = paths.map { path in
            let file = path as NSString
            let rank = (file.lastPathComponent as NSString).deletingPathExtension == preferredFileStem ? 0
                : file.deletingLastPathComponent == currentDirectory ? 1 : 2
            return (rank, path)
        }.sorted { $0 < $1 }
        var sources: [Source] = []
        var seen: Set<String> = [source.path]
        var budget = inputBudget
        for (_, path) in ordered {
            if Task.isCancelled { break }
            let url = root.appendingPathComponent(path)
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard FileReference.relativePath(of: resolved.path, root: root.path) != nil,
                  seen.insert(resolved.path).inserted,
                  let text = drafts[resolved.path] ?? readText(at: resolved),
                  text.range(of: name, options: .literal) != nil else { continue }
            let size = text.utf8.count
            guard size <= budget else { return Input(sources: sources, truncated: true) }
            budget -= size
            sources.append(Source(path: resolved.path, text: LineEnding.normalized(text)))
        }
        return Input(sources: sources, truncated: false)
    }

    private static func readText(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= fileSizeLimit,
              let data = try? Data(contentsOf: url),
              case .text(let text, _, _) = TextFileLoader.decode(data) else { return nil }
        return text
    }
}
