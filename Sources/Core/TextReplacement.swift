import Foundation

public struct TextReplacement: Codable, Equatable, Sendable {
    public let start: Int
    public let length: Int
    public let text: String

    public init(start: Int, length: Int, text: String) {
        self.start = start
        self.length = length
        self.text = text
    }

    /// 输入范围按 UTF-16 从前到后排列，编辑必须互不重叠。
    public static func apply(_ edits: [Self], to text: String) -> String? {
        let original = text as NSString
        let result = NSMutableString()
        var offset = 0
        for edit in edits {
            guard edit.start >= offset, edit.start <= original.length,
                  edit.length >= 0, edit.length <= original.length - edit.start else { return nil }
            result.append(original.substring(with: NSRange(location: offset, length: edit.start - offset)))
            result.append(edit.text)
            offset = edit.start + edit.length
        }
        result.append(original.substring(from: offset))
        return result as String
    }
}

public struct FileReplacement: Identifiable, Sendable {
    public struct PreviewLine: Identifiable, Sendable {
        public let id: String
        public let index: Int
        public let line: Int
        public let column: Int
        public let before: String
        public let after: String
    }

    public let path: String
    public let data: Data
    public let text: String
    public let encoding: String
    public let edits: [TextReplacement]
    public var id: String { path }

    public init(path: String, data: Data, text: String, encoding: String, edits: [TextReplacement]) {
        self.path = path
        self.data = data
        self.text = text
        self.encoding = encoding
        self.edits = edits
    }

    public func change(selecting indices: Set<Int>) -> FileTextTransaction.Change? {
        let edits = edits.enumerated().compactMap { indices.contains($0.offset) ? $0.element : nil }
        guard !edits.isEmpty, let modified = TextReplacement.apply(edits, to: text), modified != text else { return nil }
        // 使用原文的行尾，不为修改几处文字而改写整份文件的行尾。
        let encoded: Data
        if encoding == "UTF-16", data.starts(with: [0xFE, 0xFF]), let body = modified.data(using: .utf16BigEndian) {
            encoded = Data([0xFE, 0xFF]) + body
        } else {
            encoded = modified.data(using: TextFileSaver.encoding(named: encoding)) ?? Data(modified.utf8)
        }
        return FileTextTransaction.Change(path: path, before: data, after: encoded)
    }

    public static func preview(root: URL, paths: [String], query: TextSearchQuery, matcher: TextSearchMatcher,
                               template: String, limit: Int, shouldStop: () -> Bool = { false }) -> (files: [Self], truncated: Bool) {
        var files: [Self] = []
        var remaining = limit
        var retainedBytes = 0
        for path in Set(paths).sorted() where query.matchesMask(path) {
            if shouldStop() { break }
            guard let url = FileTextTransaction.file(path, under: root),
                  let facts = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = facts.fileSize,
                  size <= TextSearchScanner.fileSizeLimit,
                  let data = try? Data(contentsOf: url), case .text(let text, let encoding, _) = TextFileLoader.decode(data) else { continue }
            var edits: [TextReplacement] = []
            var offset = 0
            for raw in text.components(separatedBy: "\n") {
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                edits += matcher.replacements(in: line, template: template, interpretingGroups: query.isRegex).compactMap { edit in
                    let expected = (line as NSString).substring(with: NSRange(location: edit.start, length: edit.length))
                    guard expected != edit.text else { return nil }
                    let newline = raw.hasSuffix("\r") ? "\r\n" : "\n"
                    let replacement = LineEnding.normalized(edit.text).replacingOccurrences(of: "\n", with: newline)
                    return TextReplacement(start: offset + edit.start, length: edit.length, text: replacement)
                }
                offset += raw.utf16.count + 1
                if edits.count > remaining { break }
            }
            if edits.isEmpty { continue }
            retainedBytes += data.count + text.utf8.count + edits.reduce(0) { $0 + $1.text.utf8.count }
            if retainedBytes > 32 * 1024 * 1024 { return (files, true) }
            if remaining > 0 { files.append(Self(path: path, data: data, text: text, encoding: encoding, edits: Array(edits.prefix(remaining)))) }
            if edits.count > remaining { return (files, true) }
            remaining -= edits.count
        }
        return (files, false)
    }

    public func previewLines() -> [PreviewLine] {
        let original = text as NSString
        var number = 1, start = 0
        let starts = text.components(separatedBy: "\n").map { line -> Int in
            defer { start += line.utf16.count + 1 }
            return start
        }
        return edits.enumerated().map { index, edit in
            while number < starts.count, starts[number] <= edit.start { number += 1 }
            let before = original.substring(with: NSRange(location: edit.start, length: edit.length))
            return PreviewLine(id: path + "\0" + String(index), index: index, line: number,
                column: edit.start - starts[number - 1] + 1, before: before, after: edit.text)
        }
    }
}

/// 核对预览时的原始字节，再逐文件原子写入。途中失败时，撤回本批已写入的文件。
public enum FileTextTransaction {
    public struct Change: Sendable {
        public let path: String
        public let before: Data
        public let after: Data
        public let newPath: String?

        public init(path: String, before: Data, after: Data, newPath: String? = nil) {
            self.path = path
            self.before = before
            self.after = after
            self.newPath = newPath
        }
    }

    public static func file(_ path: String, under root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let original = root.appendingPathComponent(path).standardizedFileURL
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        guard original.path == resolved.path,
              FileReference.relativePath(of: resolved.path, root: root.path) != nil,
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return resolved
    }

    public static func write(_ changes: [Change], under root: URL, reversing: Bool = false) throws {
        var locations = Set<String>()
        for change in changes {
            guard locations.insert(change.path).inserted else { throw TextSearchError.failed("本批改动有重复的文件路径") }
            if let newPath = change.newPath, newPath != change.path, !locations.insert(newPath).inserted {
                throw TextSearchError.failed("本批改动中的目标路径重复：\(newPath)")
            }
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        func endpoints(_ change: Change, reverse: Bool) -> (String, Data, String, Data) {
            let destination = change.newPath ?? change.path
            return reverse ? (destination, change.after, change.path, change.before) : (change.path, change.before, destination, change.after)
        }
        func checkedURLs(_ change: Change, reverse: Bool) throws -> (URL, URL) {
            let (source, expected, destination, _) = endpoints(change, reverse: reverse)
            guard let url = file(source, under: root), (try? Data(contentsOf: url)) == expected else {
                throw TextSearchError.failed("\(source) 的内容已变化，请重新预览")
            }
            guard source != destination else { return (url, url) }
            let target = root.appendingPathComponent(destination).standardizedFileURL
            let folder = url.deletingLastPathComponent()
            guard target.deletingLastPathComponent().path == folder.path,
                  FileReference.relativePath(of: target.path, root: root.path) == destination else {
                throw TextSearchError.failed("无效的目标路径：\(destination)")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            guard names.contains(url.lastPathComponent), !names.contains(target.lastPathComponent) else {
                throw TextSearchError.failed("目标路径 \(destination) 已存在")
            }
            return (url, target)
        }
        func apply(_ change: Change, reverse: Bool) throws {
            let (from, to) = try checkedURLs(change, reverse: reverse)
            let (_, expected, _, replacement) = endpoints(change, reverse: reverse)
            try replacement.write(to: from, options: .atomic)
            guard from != to else { return }
            let intermediate = from.deletingLastPathComponent().appendingPathComponent(".agentidea-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: from, to: intermediate)
                do { try FileManager.default.moveItem(at: intermediate, to: to) }
                catch {
                    do { try FileManager.default.moveItem(at: intermediate, to: from) }
                    catch { throw TextSearchError.failed("移动失败，文件暂存在 \(intermediate.path)") }
                    throw error
                }
            } catch {
                if (try? Data(contentsOf: from)) == replacement {
                    do { try expected.write(to: from, options: .atomic) }
                    catch { throw TextSearchError.failed("移动失败，无法恢复 \(from.lastPathComponent) 的内容") }
                }
                throw error
            }
        }
        for change in changes { _ = try checkedURLs(change, reverse: reversing) }
        var written: [Change] = []
        do {
            for change in changes {
                try apply(change, reverse: reversing)
                written.append(change)
            }
        } catch {
            var failures: [String] = []
            for change in written.reversed() {
                do {
                    try apply(change, reverse: !reversing)
                } catch { failures.append(change.path) }
            }
            if failures.isEmpty { throw error }
            throw TextSearchError.failed("\(error.localizedDescription)；以下文件的恢复失败：\(failures.joined(separator: "、"))")
        }
    }
}
