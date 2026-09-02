import Foundation

/// 仓库里 `releases/latest.json`：发布脚本写，应用读。字段刻意保持最小；脚本多写的键（publishedAt）解码时忽略。
public struct UpdateManifest: Codable, Equatable, Sendable {
    public let version: String
    /// dmg 文件名，与清单同目录。
    public let fileName: String
    public let sizeBytes: Int
    /// dmg 的 sha256，下载后校验。
    public let sha256: String
    /// 这一版的变更说明，取自 CHANGELOG。
    public let notes: String?

    public init(version: String, fileName: String, sizeBytes: Int, sha256: String, notes: String? = nil) {
        self.version = version
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.notes = notes
    }

    public var parsedVersion: AppVersion? { AppVersion(version) }

    public var displaySize: String {
        let mb = Double(sizeBytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(sizeBytes) B"
    }
}

/// 更新检查的规则。
public enum UpdatePolicy {
    /// 自动检查的间隔，一天一次；要立刻知道的话菜单里有「检查更新…」。
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    public static func shouldAutoCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // 系统时间被往回调过时也放行：卡在未来的时间戳会让更新永远查不了
        guard lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= autoCheckInterval
    }

    /// 版本号解析不出来时一律判为「没有更新」：宁可不提示，也不能凭一个坏清单把用户在用的版本换掉。
    public static func hasUpdate(manifest: UpdateManifest, currentVersion: String) -> Bool {
        guard let remote = manifest.parsedVersion, let current = AppVersion(currentVersion) else { return false }
        return remote > current
    }
}
