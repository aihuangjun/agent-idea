import CryptoKit
import Foundation

/// 应用包放在哪、怎么取（**取包侧**）。
///
/// 发布产物放在本仓库的 `releases/` 目录里，由 `scripts/release.sh` 提交推送到 GitHub；
/// 应用通过 GitHub Contents API 取 `latest.json` 与 dmg。
/// 放包侧是 bash，引用不到这里的常量，所以目录名与清单名**实际有两份**，改一处必须同步改另一处。
public enum AppDistribution {
    public static let repositoryOwner = "aihuangjun"
    public static let repositoryName = "agent-idea"
    public static let branch = "main"
    /// 与 `scripts/release.sh` 的 `RELEASES` 必须一致。
    public static let releasesDirectory = "releases"
    public static let manifestName = "latest.json"

    public static var repositoryPage: URL {
        URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)")!
    }

    /// Contents API 地址。带上 `Accept: application/vnd.github.raw+json` 就直接返回文件内容，
    /// 二进制也行（上限 100MB，dmg 远小于此）。仓库是私有的，要带 token；改成公开后不带也能用。
    public static func contentsURL(fileName: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repositoryOwner)/\(repositoryName)/contents/\(releasesDirectory)/\(fileName)"
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        return components.url!
    }

    public static func request(fileName: String, token: String?) -> URLRequest {
        var request = URLRequest(url: contentsURL(fileName: fileName))
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
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

    @MainActor
    public static func resolve(
        tokenFile: URL = AppPaths.gitHubTokenFile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: CommandRunning = ShellCommand(),
        fileManager: FileManager = .default
    ) async -> String? {
        if let fromFile = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let trimmed = fromFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        guard let gh = ExecutableLocator.locate(ghSearchPaths, fileManager: fileManager) else { return nil }
        guard let output = try? await runner.run(executable: gh, arguments: ["auth", "token"], currentDirectory: nil, environment: nil),
              output.status == 0 else { return nil }
        let token = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
