import Darwin
import Foundation

/// The only filesystem entry points available to the chat agent. Every operation is relative to
/// an open project root and traverses directories without following symbolic links.
public struct AIWorkspace: Sendable {
    public struct Edit: Sendable {
        public let path: String
        public let before: Data?
        public let after: Data
    }

    public enum Problem: LocalizedError, Equatable {
        case unsuitableRoot, unsafePath, unsupportedFile, tooLarge, invalidUTF8
        case notFound, exists, changed, missingText, ambiguousText, noChange, system(Int32)

        public var errorDescription: String? {
            switch self {
            case .unsuitableRoot: return "这个目录范围过大或包含系统配置，无法用作 AI 工作区"
            case .unsafePath: return "路径必须在当前工作区内，且不能指向链接、Git 元数据或凭据"
            case .unsupportedFile: return "只支持普通文本文件"
            case .tooLarge: return "文件超过 AI 工具的大小上限"
            case .invalidUTF8: return "文件不是 UTF-8 文本"
            case .notFound: return "文件或目录不存在"
            case .exists: return "目标已存在，请读取文件后再编辑"
            case .changed: return "文件已变化，请重新读取后重试"
            case .missingText: return "找不到这段原文，请重新读取文件"
            case .ambiguousText: return "这段原文出现了多次，请提供更多上下文"
            case .noChange: return "新内容和原文相同"
            case .system(let code): return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
            }
        }
    }

    public static let maxFileBytes = 512 * 1024
    public let root: URL
    private let device: dev_t
    private let inode: ino_t

    public init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try self.init(root: root, home: home, singleFileParent: false)
    }

    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, singleFileParent: Bool) throws {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let home = home.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let rootPath = root.path.lowercased()
        let system = ["/system", "/library", "/private/etc", "/usr", "/bin", "/sbin", home + "/library"]
        let homeIsInScope = Self.isWithin(home, rootPath) && !(singleFileParent && rootPath == home)
        guard root.isFileURL, root.path != "/", !homeIsInScope,
              !system.contains(where: { Self.isWithin(rootPath, $0) || (!singleFileParent && Self.isWithin($0, rootPath)) }),
              !root.pathComponents.contains(where: Self.isProtected) else { throw Problem.unsuitableRoot }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.problem() }
        defer { close(descriptor) }
        let identity = try Self.stat(descriptor)
        self.root = root
        device = identity.st_dev
        inode = identity.st_ino
    }

    public func fileURL(for path: String) throws -> URL {
        let parts = try Self.components(path)
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    public func list(_ path: String = "") throws -> [String] {
        let listing = try directoryEntries(path)
        return listing.names + (listing.truncated ? ["… 目录内容已截断，请指定子目录"] : [])
    }

    public func search(_ query: String, under path: String) throws -> String {
        guard !query.isEmpty, !query.contains("\n"), query.utf8.count <= 1_024 else { throw Problem.unsafePath }
        var pending = [path == "." ? "" : path]
        var matches: [String] = []
        var scanned = 0
        var scannedBytes = 0
        var truncated = false
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let listing = try directoryEntries(directory)
            truncated = truncated || listing.truncated
            for name in listing.names {
                try Task.checkCancellation()
                let child = directory.isEmpty ? name : directory + "/" + name
                scanned += 1
                if name.hasSuffix("/") {
                    pending.append(String(child.dropLast()))
                } else if let data = try? withFileParent(child, { try readFile(in: $0, name: $1).0 }) {
                    scannedBytes += data.count
                    if let text = try? Self.text(data) {
                        for (index, line) in text.components(separatedBy: "\n").enumerated()
                        where line.range(of: query, options: .literal) != nil {
                            matches.append("\(child):\(index + 1): \(line.prefix(280))")
                            if matches.count == 60 { break }
                        }
                    }
                }
                if matches.count == 60 || scanned >= 2_000 || scannedBytes >= 12 * 1024 * 1024 {
                    return Self.searchOutput(matches, truncated: true)
                }
            }
        }
        try Task.checkCancellation()
        return Self.searchOutput(matches, truncated: truncated)
    }

    private static func searchOutput(_ matches: [String], truncated: Bool) -> String {
        let output = matches.isEmpty ? "没有找到匹配内容" : matches.joined(separator: "\n")
        return truncated ? output + "\n… 搜索已达到上限，请缩小到某个子目录" : output
    }

    private func directoryEntries(_ path: String) throws -> (names: [String], truncated: Bool) {
        let parts = path.isEmpty || path == "." ? [] : try Self.components(path)
        return try withDirectory(parts) { descriptor in
            let copy = dup(descriptor)
            guard copy >= 0 else { throw Self.problem() }
            guard let directory = fdopendir(copy) else { close(copy); throw Self.problem() }
            defer { closedir(directory) }

            var names: [String] = []
            var scanned = 0
            while let entry = readdir(directory) {
                try Task.checkCancellation()
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
                }
                scanned += 1
                if let name, name != ".", name != "..", !name.contains("\n"), !Self.isProtected(name) {
                    var info = Darwin.stat()
                    if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device {
                        switch info.st_mode & S_IFMT {
                        case S_IFDIR: names.append(name + "/")
                        case S_IFREG where info.st_nlink == 1: names.append(name)
                        default: break
                        }
                    }
                }
                if scanned >= 4_000 || names.count >= 500 {
                    return (names.sorted(), true)
                }
            }
            return (names.sorted(), false)
        }
    }

    public func read(_ path: String, startLine: Int, lineCount: Int) throws -> String {
        guard startLine > 0, (1...200).contains(lineCount) else { throw Problem.unsafePath }
        return try withFileParent(path) { descriptor, name in
            let (data, _) = try readFile(in: descriptor, name: name)
            let lines = try Self.text(data).components(separatedBy: "\n")
            guard startLine <= lines.count else { return "文件共有 \(lines.count) 行" }
            let end = min(lines.count, startLine - 1 + lineCount)
            var output = "\(path) · 第 \(startLine)–\(end) 行，共 \(lines.count) 行\n"
            for index in (startLine - 1)..<end {
                let line = "\(index + 1)\t\(lines[index])\n"
                if output.utf8.count + line.utf8.count > 40_000 {
                    output += String(decoding: line.utf8.prefix(max(0, 40_000 - output.utf8.count)), as: UTF8.self)
                    return output + "\n… 本次读取已截断"
                }
                output += line
            }
            return output
        }
    }

    public func replace(_ path: String, old: String, new: String) throws -> Edit {
        guard !old.isEmpty else { throw Problem.missingText }
        return try withFileParent(path) { descriptor, name in
            let (before, info) = try readFile(in: descriptor, name: name)
            let text = try Self.text(before) as NSString
            // Literal matching keeps Unicode normalization and CRLF bytes intact.
            let match = text.range(of: old, options: .literal)
            guard match.location != NSNotFound else { throw Problem.missingText }
            let remainder = NSRange(location: match.location + 1, length: text.length - match.location - 1)
            guard text.range(of: old, options: .literal, range: remainder).location == NSNotFound else { throw Problem.ambiguousText }
            let after = Data(text.replacingCharacters(in: match, with: new).utf8)
            guard before != after else { throw Problem.noChange }
            try writeFile(after, in: descriptor, name: name, original: (before, info))
            return Edit(path: path, before: before, after: after)
        }
    }

    public func create(_ path: String, text: String) throws -> Edit {
        try withFileParent(path) { descriptor, name in
            let after = Data(text.utf8)
            try writeFile(after, in: descriptor, name: name, original: nil)
            return Edit(path: path, before: nil, after: after)
        }
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func isProtected(_ part: String) -> Bool {
        let lower = part.lowercased()
        let names: Set<String> = [".git", ".hg", ".svn", ".ssh", ".gnupg", ".config", ".kbreader", ".agentidea", ".codex",
                                  ".aws", ".azure", ".kube", ".docker", ".npmrc", ".pypirc", ".netrc", ".git-credentials", "credentials.json",
                                  "secrets.json", "secrets.yml", "secrets.yaml", "id_rsa", "id_ed25519", ".build", "node_modules"]
        return names.contains(lower) || lower.hasPrefix(".env") || lower.hasPrefix(".agentidea-ai-")
            || [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".tfstate"].contains(where: { lower.hasSuffix($0) })
    }

    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
            && !$0.contains("\0") && !$0.contains("\n") && !isProtected($0) }) else { throw Problem.unsafePath }
        return parts
    }

    private func withDirectory<T>(_ parts: [String], _ body: (Int32) throws -> T) throws -> T {
        try Task.checkCancellation()
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.problem() }
        defer { close(descriptor) }
        let identity = try Self.stat(descriptor)
        guard identity.st_dev == device, identity.st_ino == inode else { throw Problem.changed }
        for part in parts {
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.problem() }
            close(descriptor)
            descriptor = next
            guard try Self.stat(descriptor).st_dev == device else { throw Problem.unsafePath }
        }
        return try body(descriptor)
    }

    private func withFileParent<T>(_ path: String, _ body: (Int32, String) throws -> T) throws -> T {
        let parts = try Self.components(path)
        return try withDirectory(Array(parts.dropLast())) { try body($0, parts[parts.count - 1]) }
    }

    private static func stat(_ descriptor: Int32) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw problem() }
        return info
    }

    private static func problem() -> Problem {
        switch errno {
        case ENOENT: return .notFound
        case EEXIST: return .exists
        case ELOOP, ENOTDIR: return .unsafePath
        default: return .system(errno)
        }
    }

    private func readFile(in directory: Int32, name: String) throws -> (Data, Darwin.stat) {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.problem() }
        defer { close(descriptor) }
        let info = try Self.stat(descriptor)
        guard info.st_dev == device, info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG else { throw Problem.unsupportedFile }
        guard info.st_size <= Self.maxFileBytes else { throw Problem.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return (data, info) }
            if count == -1, errno == EINTR { continue }
            guard count > 0 else { throw Self.problem() }
            guard data.count + count <= Self.maxFileBytes else { throw Problem.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func text(_ data: Data) throws -> String {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw Problem.invalidUTF8 }
        // Foundation's UTF-8 initializer removes a byte-order mark. Restore it before rewriting.
        return data.starts(with: [0xEF, 0xBB, 0xBF]) && !text.hasPrefix("\u{FEFF}") ? "\u{FEFF}" + text : text
    }

    private func writeFile(_ data: Data, in directory: Int32, name: String, original: (Data, Darwin.stat)?) throws {
        guard data.count <= Self.maxFileBytes else { throw Problem.tooLarge }
        guard !data.contains(0) else { throw Problem.invalidUTF8 }
        let temporary = ".agentidea-ai-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.problem() }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count, let base = bytes.baseAddress {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count == -1, errno == EINTR { continue }
                guard count > 0 else { throw Self.problem() }
                offset += count
            }
        }
        if let (expected, info) = original {
            guard fchmod(descriptor, info.st_mode & 0o777) == 0 else { throw Self.problem() }
            let (current, latest) = try readFile(in: directory, name: name)
            guard expected == current, info.st_ino == latest.st_ino else { throw Problem.changed }
            try Task.checkCancellation()
            guard renameat(directory, temporary, directory, name) == 0 else { throw Self.problem() }
        } else {
            try Task.checkCancellation()
            guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else { throw Self.problem() }
        }
    }
}
