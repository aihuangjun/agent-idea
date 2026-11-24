import Darwin
import Foundation
import SQLite3

public struct AIChatSettings: Codable, Equatable, Sendable {
    public static let defaultModel = "gpt-6.2-sol"
    public static let defaultEffort = "high"
    public static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
    static let modelPrefixes = ["gpt", "o1", "o3", "o4"]

    public var model: String
    public var effort: String
    public var keys: [String]

    public init(model: String = Self.defaultModel, effort: String = Self.defaultEffort, keys: [String] = []) {
        self.model = model
        self.effort = effort
        self.keys = keys
    }

    public var normalized: Self {
        var seen = Set<String>()
        let keys = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Self(model: model.trimmingCharacters(in: .whitespacesAndNewlines), effort: effort, keys: keys)
    }

    public var validationError: String? {
        let settings = normalized
        guard Self.modelPrefixes.contains(where: { settings.model.hasPrefix($0) }),
              settings.model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
            return "请选择 OpenAI 文本模型"
        }
        guard Self.efforts.contains(settings.effort) else { return "请选择推理档位" }
        guard settings.keys.allSatisfy({ $0.hasPrefix("sk-") && $0.count > 3 && !$0.contains(where: \.isWhitespace) }) else {
            return "每行填写一把 OpenAI API Key"
        }
        return nil
    }
}

/// Only the OpenAI fields are read. This adapter never writes to KBReader's database.
public enum KBReaderChatDefaults {
    public static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kbreader/settings.sqlite")
    }

    public static func read(from url: URL = database) -> AIChatSettings? {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { if let db { sqlite3_close(db) } }
        guard status == SQLITE_OK, let db else { return nil }
        var query: OpaquePointer?
        let sql = "SELECT key, value FROM settings WHERE key IN ('openai.api_key', 'chat.model', 'chat.effort', 'openai.model', 'openai.effort')"
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { return nil }
        defer { sqlite3_finalize(query) }

        var rows: [String: String] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            if let key = sqlite3_column_text(query, 0), let value = sqlite3_column_text(query, 1) {
                rows[String(cString: key)] = String(cString: value)
            }
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;"))
        let keys = rows["openai.api_key"]?.components(separatedBy: separators).filter { $0.hasPrefix("sk-") } ?? []
        var settings = AIChatSettings(model: rows["chat.model"] ?? rows["openai.model"] ?? AIChatSettings.defaultModel,
                                      effort: rows["chat.effort"] ?? rows["openai.effort"] ?? "high", keys: keys).normalized
        let ordered = settings.keys
        settings.keys = [0, 2].compactMap { ordered.indices.contains($0) ? ordered[$0] : nil }
        if settings.validationError != nil {
            settings.model = AIChatSettings.defaultModel
            settings.effort = "high"
        }
        return settings.keys.isEmpty ? nil : settings
    }
}

public protocol AIChatSettingsStoring: Sendable {
    func load() throws -> AIChatSettings?
    func save(_ settings: AIChatSettings) throws
}

/// As in KBReader, credentials live in a user-only file outside the project. An empty key group
/// is stored explicitly so deleting keys does not reimport them on the next launch.
public struct AIChatSettingsFile: AIChatSettingsStoring {
    public let directory: URL
    private static let name = "ai-chat.json"
    private static let limit = 64 * 1024
    private enum Field: String, CodingKey { case version, model, effort, keys }

    private struct Stored: Codable {
        let settings: AIChatSettings

        init(_ settings: AIChatSettings) { self.settings = settings }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            let saved = try AIChatSettings(from: decoder)
            // Only the former shipped default migrates. An explicit selection made here survives restarts.
            if !fields.contains(.version), saved.model == "gpt-6.1-sol", saved.effort == AIChatSettings.defaultEffort {
                settings = AIChatSettings(keys: saved.keys)
            } else {
                settings = saved
            }
        }

        func encode(to encoder: Encoder) throws {
            try settings.encode(to: encoder)
            var fields = encoder.container(keyedBy: Field.self)
            try fields.encode(1, forKey: .version)
        }
    }

    public init(directory: URL = AppPaths.configurationDirectory) { self.directory = directory }

    public func load() throws -> AIChatSettings? {
        let directory = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if directory == -1, errno == ENOENT { return nil }
        guard directory >= 0 else { throw SettingsError() }
        defer { close(directory) }
        try Self.validateDirectory(directory)

        let fd = openat(directory, Self.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd == -1, errno == ENOENT { return nil }
        guard fd >= 0 else { throw SettingsError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= Self.limit else { throw SettingsError() }
        guard let data = try file.read(upToCount: Self.limit + 1), data.count <= Self.limit,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw SettingsError() }
        return stored.settings
    }

    public func save(_ settings: AIChatSettings) throws {
        let data = try JSONEncoder().encode(Stored(settings.normalized))
        guard data.count <= Self.limit else { throw SettingsError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw SettingsError() }
        defer { close(directory) }
        try Self.validateDirectory(directory)

        let temporary = ".ai-chat-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw SettingsError() }
        defer { unlinkat(directory, temporary, 0) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        guard renameat(directory, temporary, directory, Self.name) == 0 else { throw SettingsError() }
    }

    private static func validateDirectory(_ directory: Int32) throws {
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw SettingsError()
        }
    }

    private struct SettingsError: LocalizedError {
        var errorDescription: String? { "无法读取或保存 Agent IDEA 的本机 AI 设置" }
    }
}
