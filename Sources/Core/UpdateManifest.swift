import Foundation

/// 一个可更新到的版本：从 GitHub Release 里整理出来的、更新器真正需要的几项。
public struct UpdateManifest: Equatable, Sendable {
    public let version: String
    /// dmg 文件名。
    public let fileName: String
    public let sizeBytes: Int
    /// dmg 的 sha256（小写十六进制），下载后校验。
    public let sha256: String
    /// 附件的 API 地址（`AppDistribution.assetRequest`）。
    public let downloadURL: URL
    /// 这一版的变更说明（Release 正文，来自 CHANGELOG）。
    public let notes: String?

    public init(version: String, fileName: String, sizeBytes: Int, sha256: String, downloadURL: URL, notes: String? = nil) {
        self.version = version
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.notes = notes
    }

    public var parsedVersion: AppVersion? { AppVersion(version) }

    public var displaySize: String {
        let mb = Double(sizeBytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(sizeBytes) B"
    }

    /// Release 里没有可用的 dmg 附件，或附件没有 sha256 摘要。
    public enum ReleaseError: Error, Equatable {
        case noDiskImage
        case noDigest(String)
    }

    /// 从 `GET /repos/{owner}/{repo}/releases/latest` 的 JSON 里整理出来。
    /// 版本号是 tag 去掉前缀；找第一个 `.dmg` 附件；sha256 取附件的 `digest`（形如 `sha256:…`）。
    public init(release: GitHubRelease, tagPrefix: String = AppDistribution.tagPrefix) throws {
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { throw ReleaseError.noDiskImage }
        guard let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") else { throw ReleaseError.noDigest(asset.name) }
        let tag = release.tagName
        let version = tag.hasPrefix(tagPrefix) ? String(tag.dropFirst(tagPrefix.count)) : tag
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            version: version,
            fileName: asset.name,
            sizeBytes: asset.size,
            sha256: String(digest.dropFirst("sha256:".count)).lowercased(),
            downloadURL: asset.url,
            notes: notes?.isEmpty == false ? notes : nil
        )
    }
}

/// GitHub Release 接口返回的 JSON 里我们用到的字段。
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let size: Int
        /// API 地址（`…/releases/assets/{id}`），不是 `browser_download_url`。
        public let url: URL
        /// `sha256:<hex>`；GitHub 对新上传的附件都会给。
        public let digest: String?

        public init(name: String, size: Int, url: URL, digest: String?) {
            self.name = name
            self.size = size
            self.url = url
            self.digest = digest
        }
    }

    public let tagName: String
    public let body: String?
    public let assets: [Asset]

    public init(tagName: String, body: String?, assets: [Asset]) {
        self.tagName = tagName
        self.body = body
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, assets
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
    /// 本地迭代中的构建（`debug` 渠道）遇到**同一个版本号**的正式发布也算有更新：`0.6.0(…-debug)` 应该能升到发出去的 0.6.0，
    /// 否则装着 debug 包的机器在这一版永远「已是最新」。
    public static func hasUpdate(manifest: UpdateManifest, current: BuildIdentity) -> Bool {
        guard let remote = manifest.parsedVersion, let currentVersion = AppVersion(current.version) else { return false }
        if remote > currentVersion { return true }
        return remote == currentVersion && current.channel == .debug
    }
}
