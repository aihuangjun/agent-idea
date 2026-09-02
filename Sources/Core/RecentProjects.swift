import Foundation

/// 最近打开过的一个项目。
public struct RecentProject: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let lastOpened: Date

    public init(path: String, lastOpened: Date) {
        self.path = path
        self.lastOpened = lastOpened
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { url.lastPathComponent }
    /// `~/ai/agent-idea` 这种给人看的短路径。
    public var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// 最近项目列表的纯逻辑：最新的排在最前、同一路径只留一条、超出上限的丢掉。
public enum RecentProjects {
    public static let limit = 20

    public static func adding(_ url: URL, to list: [RecentProject], now: Date = Date()) -> [RecentProject] {
        let path = url.standardizedFileURL.path
        var result = list.filter { $0.path != path }
        result.insert(RecentProject(path: path, lastOpened: now), at: 0)
        return Array(result.prefix(limit))
    }

    public static func removing(_ path: String, from list: [RecentProject]) -> [RecentProject] {
        list.filter { $0.path != path }
    }

    /// 已经不存在的目录不该再出现在欢迎页上。
    public static func pruningMissing(_ list: [RecentProject], fileManager: FileManager = .default) -> [RecentProject] {
        list.filter { fileManager.fileExists(atPath: $0.path) }
    }
}
