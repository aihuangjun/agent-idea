import Foundation

/// Finder 拖入的每个文件都对应一个目标路径，保留原名并拒绝覆盖。
public enum FileImport {
    public struct Item: Sendable {
        public let source: URL
        public let destination: URL
    }

    public enum Problem: LocalizedError {
        case notARegularFile(String)
        case duplicateName(String)

        public var errorDescription: String? {
            switch self {
            case .notARegularFile(let name): return "“\(name)”不是普通文件"
            case .duplicateName(let name): return "目标目录下已经有同名的文件：“\(name)”"
            }
        }
    }

    public static func plan(_ sources: [URL], into directory: URL, fileManager: FileManager = .default) throws -> [Item] {
        var destinations: Set<URL> = []
        return try sources.map { source in
            guard source.isFileURL,
                  try fileManager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else {
                throw Problem.notARegularFile(source.lastPathComponent)
            }
            let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            guard destinations.insert(destination).inserted,
                  (try? fileManager.attributesOfItem(atPath: destination.path)) == nil else {
                throw Problem.duplicateName(source.lastPathComponent)
            }
            return Item(source: source, destination: destination)
        }
    }
}
