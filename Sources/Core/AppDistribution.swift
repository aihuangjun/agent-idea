import CryptoKit
import Foundation

/// 应用包放在哪、怎么取（**取包侧**）。
///
/// 发布产物放在本仓库的 GitHub Releases 里：每个版本一个 tag（`v1.2.0`），dmg 作为附件，
/// 由 `scripts/release.sh` 用 `gh release create` 上传。应用读 `releases/latest` 接口，
/// 从附件的 `digest` 字段拿 sha256 校验下载。仓库是私有的，要带 token；改成公开后不带也能用。
/// 放包侧是 bash，引用不到这里的常量，所以 tag 前缀**实际有两份**，改一处必须同步改另一处。
public enum AppDistribution {
    public static let repositoryOwner = "aihuangjun"
    public static let repositoryName = "agent-idea"
    /// 与 `scripts/release.sh` 的 `TAG="v$VERSION"` 必须一致。
    public static let tagPrefix = "v"

    /// 最新一个正式 Release（不含 pre-release 与草稿）。
    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    }

    public static func latestReleaseRequest(token: String?) -> URLRequest {
        request(url: latestReleaseURL, accept: "application/vnd.github+json", token: token)
    }

    /// 下载附件：对附件的 API 地址带 `Accept: application/octet-stream`，GitHub 会 302 到真正的文件地址。
    /// 私有仓库必须走这个地址（`browser_download_url` 只认浏览器会话）。
    public static func assetRequest(url: URL, token: String?) -> URLRequest {
        request(url: url, accept: "application/octet-stream", token: token)
    }

    private static func request(url: URL, accept: String, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AgentIDEA-Updater", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        return request
    }

    /// 文件的 sha256（小写十六进制），分块读。
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 访问私有仓库用的 token 从哪来。按顺序：
/// 1. `~/.agentidea/github_token` 文件（给没装 gh 的同事）；
/// 2. 环境变量 `GITHUB_TOKEN` / `GH_TOKEN`；
/// 3. 本机 `gh auth token`（装了 gh 并登录过的开发机什么都不用配）。
public enum GitHubToken {
    public static let ghSearchPaths = ["/usr/local/bin/gh", "/opt/homebrew/bin/gh", "/usr/bin/gh"]

    public static func resolve() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let fromFile = try? String(contentsOf: AppPaths.gitHubTokenFile, encoding: .utf8) {
            let trimmed = fromFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        guard let gh = ExecutableLocator.locate(ghSearchPaths) else { return nil }
        guard let output = try? await ShellCommand().run(executable: gh, arguments: ["auth", "token"], currentDirectory: nil, environment: nil),
              output.status == 0 else { return nil }
        let token = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
