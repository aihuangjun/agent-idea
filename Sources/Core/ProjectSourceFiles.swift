import Foundation

/// 只把发生变化的源码送进解析器。路径始终相对项目根，缓存版本区分磁盘和草稿。
public enum ProjectSourceFiles {
    public enum Version: Equatable, Sendable {
        case disk(modified: Date, size: Int)
        case draft(fingerprint: String)
    }

    public struct Batch: Sendable {
        public var versions: [String: Version] = [:]
        public var changed: [DefinitionSearch.Source] = []
        public var skipped = 0
    }

    public static func prepare(
        _ paths: [FileSearchEntry], root: URL, drafts: [String: String], cached: [String: Version],
        shouldStop: () -> Bool = { false }
    ) -> Batch {
        var batch = Batch()
        for entry in paths {
            if shouldStop() { break }
            let url = root.appendingPathComponent(entry.path)
            guard !DefinitionSearch.extensions(for: url).isEmpty else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard FileReference.relativePath(of: resolved.path, root: root.path) != nil else { continue }
            let text: String?
            let version: Version
            if let draft = drafts[resolved.path] {
                guard draft.utf8.count <= TextSearchScanner.fileSizeLimit else { batch.skipped += 1; continue }
                text = draft
                version = .draft(fingerprint: TextFingerprint.of(draft))
            } else {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                guard let facts = try? resolved.resourceValues(forKeys: keys), facts.isRegularFile == true,
                      let size = facts.fileSize, let modified = facts.contentModificationDate else { continue }
                guard size <= TextSearchScanner.fileSizeLimit else { batch.skipped += 1; continue }
                version = .disk(modified: modified, size: size)
                if cached[entry.path] == version {
                    batch.versions[entry.path] = version
                    continue
                }
                if let data = try? Data(contentsOf: resolved), case .text(let decoded, _, _) = TextFileLoader.decode(data) {
                    text = decoded
                } else {
                    text = nil
                }
            }
            guard let text else { batch.skipped += 1; continue }
            batch.versions[entry.path] = version
            if cached[entry.path] != version {
                batch.changed.append(DefinitionSearch.Source(path: entry.path, text: LineEnding.normalized(text)))
            }
        }
        return batch
    }
}
