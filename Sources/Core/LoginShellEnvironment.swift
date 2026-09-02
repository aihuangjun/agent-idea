import Foundation

/// 登录 shell 的环境变量。
///
/// 双击启动的 GUI 应用拿到的环境只有系统给的几条：PATH 是 `/usr/bin:/bin:/usr/sbin:/sbin`，
/// 没有 `SSH_AUTH_SOCK`、没有 Homebrew 的路径、没有代理变量。于是 `git push` 在终端里好好的，
/// 到了应用里要么找不到 ssh key（passphrase 的 key 靠 agent）、要么找不到 `gh` 这个凭据助手。
/// 所以起一次用户的登录 shell，把它的环境抓下来给 git 用。只跑一次并缓存。
public enum LoginShellEnvironment {
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var loaded: [String: String]?
    }

    /// 抓到的环境；还没抓过就先返回当前进程的。
    public static var current: [String: String] {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.loaded ?? ProcessInfo.processInfo.environment
    }

    /// 启动时在后台调一次。失败就保持进程环境，不影响别的功能。
    public static func load(shell: String? = nil, runner: CommandRunning = ShellCommand()) async {
        let shellPath = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `-l` 读 .zprofile / .profile；`-i` 读 .zshrc（很多人把 PATH 写在那里）。
        // 交互模式下 shell 可能打印提示语，所以用 `env -0` 以 NUL 分隔，只解析形如 KEY=VALUE 的段。
        guard let output = try? await runner.run(
            executable: URL(fileURLWithPath: shellPath),
            arguments: ["-lic", "/usr/bin/env -0"],
            currentDirectory: nil,
            environment: nil
        ), output.status == 0 else { return }
        let parsed = parse(output.standardOutput)
        guard !parsed.isEmpty else { return }
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in parsed { merged[key] = value }
        override(merged)
        Log.info("env", "已载入登录 shell 环境（\(parsed.count) 项）")
    }

    public static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for chunk in data.split(separator: 0) {
            let entry = String(decoding: chunk, as: UTF8.self)
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            // 只要长得像变量名的：交互 shell 的输出里可能混进别的东西
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            result[key] = String(entry[entry.index(after: equals)...])
        }
        return result
    }

    /// 测试用：直接塞一份。
    public static func override(_ environment: [String: String]?) {
        cache.lock.lock()
        cache.loaded = environment
        cache.lock.unlock()
    }
}
