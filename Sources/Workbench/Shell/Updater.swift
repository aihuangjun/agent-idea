import AppKit
import Core
import Foundation

/// 应用内更新：查、下、换、重启。包放在仓库的 GitHub Releases 里（见 `AppDistribution`）。
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading
        case readyToRelaunch(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 手动触发的检查要给反馈（哪怕结果是「已经是最新」）；自动检查则安静。
    @Published private(set) var isUserInitiated = false

    let build: BuildIdentity
    var currentVersion: String { build.version }
    private let installedAppURL: URL
    private let defaults: UserDefaults
    private let lastCheckKey = "updater.lastCheck"
    private var work: Task<Void, Never>?

    init() {
        build = .current
        installedAppURL = Bundle.main.bundleURL
        defaults = .standard
    }

    var lastCheck: Date? { defaults.object(forKey: lastCheckKey) as? Date }

    /// 启动后调用。距上次检查不足一天就什么都不做。
    func checkInBackgroundIfDue() {
        guard UpdatePolicy.shouldAutoCheck(lastCheck: lastCheck, now: Date()) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool = true) {
        guard work == nil else { return }
        isUserInitiated = userInitiated
        phase = .checking
        work = Task { [weak self] in
            defer { self?.work = nil }
            await self?.performCheck()
        }
    }

    func dismiss() { phase = .idle }

    private func performCheck() async {
        defaults.set(Date(), forKey: lastCheckKey)
        do {
            let manifest = try await fetchManifest()
            guard UpdatePolicy.hasUpdate(manifest: manifest, current: build) else {
                phase = .upToDate
                return
            }
            phase = .available(manifest)
        } catch {
            Log.warn("update", "检查失败：\(error)")
            phase = .failed(Self.describe(error))
        }
    }

    func install(_ manifest: UpdateManifest) {
        guard work == nil else { return }
        phase = .downloading
        work = Task { [weak self] in
            defer { self?.work = nil }
            guard let self else { return }
            do {
                let dmg = try await self.download(manifest)
                try await self.replaceInstalledApp(with: dmg)
                self.phase = .readyToRelaunch(manifest)
            } catch {
                Log.warn("update", "安装失败：\(error)")
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    /// 退出自己并拉起新版本：起一个小脚本盯着本进程退出，再由它 open 新版本。
    /// 本进程一直不退（退出被取消了）就什么都不做：这时 `open` 只会把还活着的旧实例激活一下，等它真退出时就没人拉新的了。
    func relaunch() {
        let script = """
        #!/bin/bash
        for _ in $(seq 1 600); do
          kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || { open \(Self.shellQuoted(installedAppURL.path)); break; }
          sleep 0.1
        done
        rm -f "$0"
        """
        do {
            let url = try Self.writeTemporaryScript(script, name: "agentidea-relaunch")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [url.path]
            try process.run()
        } catch {
            phase = .failed("无法重启：\(error.localizedDescription)")
            return
        }
        // 先把对话框收掉、下一轮事件循环再退出：sheet 还挂在窗口上时 `terminate` 会被 AppKit 直接取消并立即返回，
        // 按钮看起来就像没反应（0.6.2 修的；实测收掉 sheet 后 0.4s 内退出）。
        phase = .idle
        DispatchQueue.main.async { [weak self] in
            NSApp.terminate(nil)
            // 走到这里说明退出被取消了（别的 sheet、模态窗口……），别让人干等
            Log.warn("update", "退出被取消，没能自动重启")
            self?.phase = .failed("新版本已经装好，但没能自动退出。请手动退出应用后重新打开。")
        }
    }

    // MARK: - 具体步骤

    private func fetchManifest() async throws -> UpdateManifest {
        let token = await GitHubToken.resolve()
        let (data, response) = try await URLSession.shared.data(for: AppDistribution.latestReleaseRequest(token: token))
        try Self.check(response, hadToken: token != nil)
        do {
            return try UpdateManifest(release: JSONDecoder().decode(GitHubRelease.self, from: data))
        } catch {
            Log.warn("update", "Release 信息读不出来：\(error)")
            throw UpdateError.badManifest
        }
    }

    private func download(_ manifest: UpdateManifest) async throws -> URL {
        let token = await GitHubToken.resolve()
        let request = AppDistribution.assetRequest(url: manifest.downloadURL, token: token)
        // GitHub 会 302 到对象存储；那边见到 Authorization 头会拒绝，重定向时要把它摘掉
        let session = URLSession(configuration: .ephemeral, delegate: RedirectSanitizer(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(for: request)
        try Self.check(response, hadToken: token != nil)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-update-\(manifest.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        let actual = try AppDistribution.sha256(ofFileAt: destination)
        guard actual.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError.checksumMismatch
        }
        return destination
    }

    /// 挂载 dmg，把里面的 app 换到当前位置，再卸载。
    /// 顺序是「旧的先改名让位 → 新的挪进来 → 确认成功再删旧的」，中途失败 trap 把旧版本换回去。
    private func replaceInstalledApp(with dmg: URL) async throws {
        let script = """
        #!/bin/bash
        set -euo pipefail
        DMG=\(Self.shellQuoted(dmg.path))
        TARGET=\(Self.shellQuoted(installedAppURL.path))
        STAGING="$TARGET.new"
        BACKUP="$TARGET.old"
        MOUNT=""
        cleanup() {
          status=$?
          if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
          if [ ! -e "$TARGET" ] && [ -e "$BACKUP" ]; then mv "$BACKUP" "$TARGET" || true; fi
          rm -rf "$STAGING" 2>/dev/null || true
          if [ -e "$TARGET" ]; then rm -rf "$BACKUP" 2>/dev/null || true; fi
          exit $status
        }
        trap cleanup EXIT
        if [ ! -e "$TARGET" ] && [ -e "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
        MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly | tail -1 | cut -f3-)
        [ -d "$MOUNT/AgentIDEA.app" ] || { echo "dmg 里没有 AgentIDEA.app"; exit 1; }
        rm -rf "$STAGING" "$BACKUP"
        cp -R "$MOUNT/AgentIDEA.app" "$STAGING"
        if [ -e "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
        mv "$STAGING" "$TARGET"
        """
        let url = try Self.writeTemporaryScript(script, name: "agentidea-install")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: dmg)
        }
        _ = try await ShellCommand().runChecked(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [url.path])
    }

    // MARK: - 杂项

    enum UpdateError: Error {
        case badManifest
        case checksumMismatch
        case http(Int, hadToken: Bool)
    }

    private static func check(_ response: URLResponse, hadToken: Bool) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.http(http.statusCode, hadToken: hadToken) }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.badManifest:
            return "更新信息读不出来（最新 Release 里没有带摘要的 dmg 附件），请联系发布者。"
        case UpdateError.checksumMismatch:
            return "下载的安装包校验不通过，已丢弃。请稍后重试。"
        case UpdateError.http(404, hadToken: true):
            // 带着 token 还 404：文件不在。最可能是还没发布过任何版本
            return "仓库里还没有发布过 Release，或者当前 token 没有这个仓库的读权限。"
        case UpdateError.http(let status, let hadToken) where status == 401 || status == 403 || status == 404:
            let hint = hadToken
                ? "当前 token 没有这个仓库的读权限。"
                : "没有找到可用的 GitHub 凭据。"
            return """
            访问更新仓库被拒绝（HTTP \(status)）。\(hint)
            仓库是私有的：装好 gh 并登录（brew install gh && gh auth login），
            或把一个有 repo 读权限的 token 写进 ~/.agentidea/github_token。
            """
        case UpdateError.http(let status, _):
            return "GitHub 返回了 HTTP \(status)，请稍后重试。"
        default:
            return error.userFacingDescription
        }
    }

    /// 跨到别的主机的重定向不带 Authorization。GitHub 附件下载 302 到 objects.githubusercontent.com，
    /// 那边带着 GitHub 的 token 会返回 400。
    private final class RedirectSanitizer: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var sanitized = request
            if request.url?.host != task.originalRequest?.url?.host {
                sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(sanitized)
        }
    }

    private static func writeTemporaryScript(_ contents: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).sh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
