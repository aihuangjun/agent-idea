import Foundation

public struct GitBlameLine: Equatable, Sendable {
    public let line: Int
    public let originalLine: Int
    public let hash: String?
    public let author: String
    public let date: Date?
    public let summary: String
    public let path: String
}

public enum GitBlameParser {
    static func isObjectID(_ value: some StringProtocol) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func parse(_ text: String) -> [GitBlameLine] {
        var rows: [GitBlameLine] = []
        var header: (hash: String, original: Int, line: Int)?
        var author = "", summary = "", path = ""
        var date: Date?
        for row in text.components(separatedBy: "\n") {
            if row.hasPrefix("\t") {
                if let header {
                    let hash = header.hash.utf8.allSatisfy { $0 == 48 } ? nil : header.hash
                    rows.append(.init(line: header.line, originalLine: header.original, hash: hash,
                        author: author, date: date, summary: summary, path: path))
                }
                header = nil
                continue
            }
            if header == nil {
                let fields = row.split(separator: " ")
                guard fields.count == 3 || fields.count == 4, isObjectID(fields[0]),
                      let original = Int(fields[1]), let line = Int(fields[2]), original > 0, line > 0 else { continue }
                header = (String(fields[0]), original, line)
                author = ""; summary = ""; path = ""; date = nil
                continue
            }
            if row.hasPrefix("author ") { author = String(row.dropFirst(7)) }
            if row.hasPrefix("author-time "), let seconds = TimeInterval(row.dropFirst(12)) { date = Date(timeIntervalSince1970: seconds) }
            if row.hasPrefix("summary ") { summary = String(row.dropFirst(8)) }
            if row.hasPrefix("filename ") { path = unquote(String(row.dropFirst(9))) }
        }
        return rows
    }

    /// Git quotes whitespace and non-ASCII bytes with C escapes in porcelain filenames.
    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92]
        let source = Array(path.dropFirst().dropLast().utf8)
        var output: [UInt8] = []
        var index = 0
        while index < source.count {
            let byte = source[index]
            index += 1
            guard byte == 92, index < source.count else { output.append(byte); continue }
            if index + 2 < source.count, source[index..<index + 3].allSatisfy({ (48...55).contains($0) }) {
                let value = source[index..<index + 3].reduce(0) { $0 * 8 + Int($1 - 48) }
                output.append(UInt8(truncatingIfNeeded: value))
                index += 3
            } else {
                output.append(escapes[source[index]] ?? source[index]); index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

extension GitClient {
    public func blame(path: String, contents: Data, repositoryRoot: URL) async throws -> [GitBlameLine] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-blame-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("buffer")
        try contents.write(to: file)
        let args = ["blame", "--line-porcelain", "--contents", file.path, "--", path]
        let result = try await runner.run(executable: executable, arguments: args, currentDirectory: repositoryRoot, environment: Self.environment)
        guard result.status == 0 else { throw ShellCommandError(command: "git blame", status: Int(result.status), message: result.standardError) }
        return GitBlameParser.parse(result.text)
    }

    public func commit(hash: String, repositoryRoot: URL) async throws -> GitCommit? {
        guard GitBlameParser.isObjectID(hash) else { return nil }
        let args = ["log", "-1", "-z", "--format=" + GitLogParser.format, hash, "--"]
        let result = try await runner.run(executable: executable, arguments: args, currentDirectory: repositoryRoot, environment: Self.environment)
        guard result.status == 0 else { throw ShellCommandError(command: "git log", status: Int(result.status), message: result.standardError) }
        return GitLogParser.parse(result.standardOutput).first
    }
}
