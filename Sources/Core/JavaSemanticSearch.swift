import Foundation

/// The compiler resolves declarations and references from source snapshots. Paths and offsets are
/// project-relative and UTF-16, matching the editor. The helper emits only requested results.
public enum JavaSemanticSearch {
    public enum Action: String, Sendable { case usages, rename, implementations, hierarchy }

    public struct Selection: Decodable, Sendable {
        public let line: Int
        public let ch: Int
        public let length: Int

        public init(line: Int, ch: Int, length: Int = 0) {
            self.line = line
            self.ch = ch
            self.length = length
        }
    }

    public struct Source: Sendable {
        public let path: String
        public let data: Data
        public let original: String
        public let encoding: String
        public var text: String
    }

    public struct Snapshot: Sendable {
        public var sources: [Source]
        public let incomplete: Bool
    }

    public struct Location: Hashable, Identifiable, Sendable {
        public let path: String
        public let start: Int
        public let length: Int
        public let line: Int
        public let column: Int
        public let title: String
        public var id: String { path + "\n" + String(start) }
    }

    public struct Edge: Identifiable, Sendable {
        public let from: String
        public let to: String
        public let site: Location
        public var id: String { site.id }
    }

    public struct Result: Sendable {
        public var name: String?
        public var title: String?
        public var isTopLevelType = false
        public var declaration: Location?
        public var hits: [Location] = []
        public var nodes: [Location] = []
        public var edges: [Edge] = []
        public var errors = 0
        public var incomplete = false
        public var externalOverride = false
    }

    public struct RenamePreview: Sendable {
        public let files: [FileReplacement]
        public let changes: [FileTextTransaction.Change]
        public let sourceSnapshot: Snapshot
    }

    public static func prepareRename(_ result: Result, to proposed: String, snapshot: Snapshot, script: URL) async throws -> RenamePreview {
        guard let name = result.name, let declaration = result.declaration, !result.hits.isEmpty,
              proposed != name, !proposed.isEmpty, proposed == proposed.trimmingCharacters(in: .whitespacesAndNewlines),
              proposed.utf16.count <= 255, proposed.unicodeScalars.allSatisfy({ $0 == "$" || $0 == "_" || CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }) else {
            throw TextSearchError.failed("请输入不同的有效 Java 标识符")
        }
        guard !result.incomplete, result.errors == 0, !result.externalOverride else {
            throw TextSearchError.failed("项目依赖或引用未能完整解析，无法安全重命名")
        }
        let grouped = Dictionary(grouping: result.hits, by: \.path)
        var verification = snapshot
        var files: [FileReplacement] = []
        var changes: [FileTextTransaction.Change] = []
        var expected = Set<String>()
        var resolvePath = declaration.path
        var resolveSelection = Selection(line: declaration.line, ch: declaration.column, length: proposed.utf16.count)
        for (index, source) in snapshot.sources.enumerated() {
            try Task.checkCancellation()
            guard let hits = grouped[source.path] else { continue }
            guard LineEnding.normalized(source.original) == source.text else {
                throw TextSearchError.failed("\(source.path) 有未保存的编辑，请保存后再重命名")
            }
            let destination: String?
            if source.path == declaration.path, result.isTopLevelType,
               (source.path as NSString).lastPathComponent == name + ".java" {
                let directory = (source.path as NSString).deletingLastPathComponent
                destination = directory.isEmpty ? proposed + ".java" : directory + "/" + proposed + ".java"
                resolvePath = destination ?? source.path
            } else { destination = nil }
            let originalLines = source.original.components(separatedBy: "\n")
            var offsets = [0]
            for line in originalLines { offsets.append(offsets.last! + line.utf16.count + 1) }
            var rawEdits: [TextReplacement] = []
            var normalizedEdits: [TextReplacement] = []
            var shift = 0
            var columnsShift = 0
            var currentLine = -1
            for hit in hits {
                guard originalLines.indices.contains(hit.line), hit.length == name.utf16.count,
                      hit.column + hit.length <= originalLines[hit.line].utf16.count,
                      (originalLines[hit.line] as NSString).substring(with: NSRange(location: hit.column, length: hit.length)) == name else {
                    throw TextSearchError.failed("引用位置已变化，请重新查找")
                }
                if hit.line != currentLine { currentLine = hit.line; columnsShift = 0 }
                let actualDestination = destination ?? source.path
                expected.insert(actualDestination + "\n" + String(hit.start + shift))
                if hit.id == declaration.id { resolveSelection = Selection(line: hit.line, ch: hit.column + columnsShift, length: proposed.utf16.count) }
                rawEdits.append(TextReplacement(start: offsets[hit.line] + hit.column, length: hit.length, text: proposed))
                normalizedEdits.append(TextReplacement(start: hit.start, length: hit.length, text: proposed))
                let delta = proposed.utf16.count - hit.length
                shift += delta
                columnsShift += delta
            }
            guard let text = TextReplacement.apply(normalizedEdits, to: source.text) else {
                throw TextSearchError.failed("引用位置重复，请重新查找")
            }
            let file = FileReplacement(path: source.path, data: source.data, text: source.original, encoding: source.encoding, edits: rawEdits)
            guard let change = file.change(selecting: Set(rawEdits.indices)) else { continue }
            files.append(file)
            changes.append(.init(path: change.path, before: change.before, after: change.after, newPath: destination))
            verification.sources[index] = Source(path: destination ?? source.path, data: source.data,
                                                 original: source.original, encoding: source.encoding, text: text)
        }
        let verified = try await analyze(.rename, path: resolvePath, selection: resolveSelection, in: verification, using: script)
        guard verified.errors == 0, !verified.incomplete, !verified.externalOverride, verified.name == proposed,
              Set(verified.hits.map(\.id)) == expected else {
            throw TextSearchError.failed("重命名会造成名称冲突或改变现有引用，请使用其他名称")
        }
        return RenamePreview(files: files, changes: changes, sourceSnapshot: snapshot)
    }

    public static func snapshot(root: URL, drafts: [String: String],
                                isExcluded: @Sendable (String, Bool) -> Bool) async throws -> Snapshot {
        let files = FileIndexer.index(root: root, shouldStop: { Task.isCancelled }, isExcluded: isExcluded)
        var sources: [Source] = []
        var incomplete = files.count >= FileIndexer.defaultLimit
        var bytes = 0
        let budget = 64 * 1024 * 1024
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard file.path.lowercased().hasSuffix(".java"), file.name != "module-info.java" else { continue }
            guard let url = FileTextTransaction.file(file.path, under: root),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= TextSearchScanner.fileSizeLimit,
                  let data = try? Data(contentsOf: url), case .text(let original, let encoding, _) = TextFileLoader.decode(data) else {
                incomplete = true
                continue
            }
            let text = LineEnding.normalized(drafts[url.path] ?? original)
            bytes += text.utf8.count
            if bytes > budget || sources.count >= 8_000 { incomplete = true; break }
            sources.append(Source(path: file.path, data: data, original: original, encoding: encoding, text: text))
        }
        return Snapshot(sources: sources, incomplete: incomplete)
    }

    public static func offset(_ selection: Selection, in text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(selection.line), selection.ch >= 0, selection.length >= 0,
              selection.ch <= lines[selection.line].utf16.count,
              selection.length <= lines[selection.line].utf16.count - selection.ch else { return nil }
        return lines[..<selection.line].reduce(selection.ch) { $0 + $1.utf16.count + 1 }
    }

    public static func analyze(_ action: Action, path: String, selection: Selection, in snapshot: Snapshot,
                               using script: URL, runner: any CommandRunning = ShellCommand()) async throws -> Result {
        guard let text = snapshot.sources.first(where: { $0.path == path })?.text,
              let start = offset(selection, in: text) else { return Result(incomplete: snapshot.incomplete) }
        let env = environment
        let executable = try await java(runner, env: env)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-java-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("empty"), withIntermediateDirectories: false)
        var manifest = ""
        for (index, source) in snapshot.sources.enumerated() {
            try Task.checkCancellation()
            let file = "\(index).txt"
            try Data(source.text.utf8).write(to: temporary.appendingPathComponent(file))
            manifest += "\(Data(source.path.utf8).base64EncodedString())\t\(file)\n"
        }
        let manifestURL = temporary.appendingPathComponent("sources.tsv")
        try Data(manifest.utf8).write(to: manifestURL)
        let output = try await runner.run(executable: executable,
            arguments: ["-Xmx768m", "--class-path", temporary.appendingPathComponent("empty").path, script.path,
                        manifestURL.path, action.rawValue, path, String(start), String(start + selection.length)],
            currentDirectory: temporary, environment: env, stallTimeout: 45)
        guard output.status == 0 else {
            Log.warn("java", "javac 分析失败：\(output.standardError.prefix(2000))")
            throw TextSearchError.failed("Java 源码分析失败，请检查 JDK 与项目源码")
        }
        return parse(output.text, incomplete: snapshot.incomplete)
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // The app controls the Java options and classpath. The project cannot inject agents or processors.
        for name in ["JDK_JAVA_OPTIONS", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "CLASSPATH", "DYLD_INSERT_LIBRARIES"] { env[name] = nil }
        return env
    }

    private static func java(_ runner: any CommandRunning, env: [String: String]) async throws -> URL {
        func executable(home: String) -> URL? {
            guard FileManager.default.isExecutableFile(atPath: home + "/bin/javac") else { return nil }
            return ExecutableLocator.locate([home + "/bin/java"])
        }
        if let home = env["JAVA_HOME"], !home.isEmpty, let url = executable(home: home),
           let release = try? String(contentsOfFile: home + "/release", encoding: .utf8),
           let version = release.split(separator: "\n").first(where: { $0.hasPrefix("JAVA_VERSION=\"") })?.dropFirst(14),
           let major = Int(version.prefix(while: \.isNumber)), major >= 17 {
            return url
        }
        let output = try await runner.run(executable: URL(fileURLWithPath: "/usr/libexec/java_home"),
            arguments: ["-X"], currentDirectory: nil, environment: env)
        if output.status == 0,
           let entries = try? PropertyListSerialization.propertyList(from: output.standardOutput, format: nil) as? [[String: Any]] {
            for entry in entries {
                guard entry["JVMEnabled"] as? Bool != false,
                      let version = entry["JVMVersion"] as? String,
                      let major = Int(version.prefix(while: \.isNumber)), major >= 17,
                      let home = entry["JVMHomePath"] as? String, let url = executable(home: home) else { continue }
                return url
            }
        }
        throw TextSearchError.failed("Java 语义分析需要 JDK 17 或更新版本")
    }

    static func parse(_ text: String, incomplete: Bool) -> Result {
        var result = Result(incomplete: incomplete)
        func decoded(_ encoded: Substring) -> String? {
            Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) }
        }
        func location(_ fields: [Substring], at i: Int) -> Location? {
            guard fields.count == i + 6, let path = decoded(fields[i]), let start = Int(fields[i + 1]),
                  let length = Int(fields[i + 2]), let line = Int(fields[i + 3]), let column = Int(fields[i + 4]),
                  let title = decoded(fields[i + 5]), start >= 0, length > 0, line >= 0, column >= 0 else { return nil }
            return Location(path: path, start: start, length: length, line: line, column: column, title: title)
        }
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            switch fields.first {
            case "errors" where fields.count == 2: result.errors = Int(fields[1]) ?? 0
            case "symbol" where fields.count == 3:
                result.name = decoded(fields[1])
                result.title = decoded(fields[2])
            case "declaration": result.declaration = location(fields, at: 1)
            case "hit": if let hit = location(fields, at: 1) { result.hits.append(hit) }
            case "node": if let node = location(fields, at: 1) { result.nodes.append(node) }
            case "edge" where fields.count == 9:
                if let from = decoded(fields[1]), let to = decoded(fields[2]), let site = location(fields, at: 3) {
                    result.edges.append(Edge(from: from, to: to, site: site))
                }
            case "truncated": result.incomplete = true
            case "externalOverride": result.externalOverride = true
            case "topLevelType": result.isTopLevelType = true
            default: break
            }
        }
        result.hits.sort { ($0.path, $0.start) < ($1.path, $1.start) }
        return result
    }
}
