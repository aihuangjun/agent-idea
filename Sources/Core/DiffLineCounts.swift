import Foundation

public struct DiffLineCounts: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let isBinary: Bool

    public init(added: Int, removed: Int, isBinary: Bool = false) {
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
    }

    public static let binary = DiffLineCounts(added: 0, removed: 0, isBinary: true)
}

/// `git diff --numstat -z`：重命名多带两个 NUL 分隔的路径，路径里的制表符、换行都不能按行拆。
public enum GitNumstatParser {
    public static func parse(_ data: Data) -> [String: DiffLineCounts] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        var result: [String: DiffLineCounts] = [:]
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard let first = record.firstIndex(of: "\t"), let second = record[record.index(after: first)...].firstIndex(of: "\t") else { continue }
            let added = record[..<first], removed = record[record.index(after: first)..<second]
            var path = String(record[record.index(after: second)...])
            if path.isEmpty {
                guard index + 1 < fields.count else { break }
                path = String(fields[index + 1])
                index += 2
            }
            guard !path.isEmpty else { continue }
            if added == "-", removed == "-" { result[path] = .binary }
            else if let plus = Int(added), let minus = Int(removed), plus >= 0, minus >= 0 {
                result[path] = DiffLineCounts(added: plus, removed: minus)
            }
        }
        return result
    }
}

public extension DiffLineCounts {
    /// 未跟踪文件全部算新增。流式计数，既不为每个文件起 git，也不把大文件整体读入内存。
    static func addedFile(at url: URL) throws -> DiffLineCounts? {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try manager.destinationOfSymbolicLink(atPath: url.path)
            return DiffLineCounts(added: target.utf8.filter { $0 == 10 }.count + (target.hasSuffix("\n") ? 0 : 1), removed: 0)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lines = 0
        var last: UInt8?
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            if data.contains(0) { return .binary }
            lines += data.filter { $0 == 10 }.count
            last = data.last
        }
        return DiffLineCounts(added: lines + (last != nil && last != 10 ? 1 : 0), removed: 0)
    }
}
