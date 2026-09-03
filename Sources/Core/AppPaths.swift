import Foundation

/// 本地状态往哪儿放：全部收在 `~/.agentidea/` 下，用户一眼能找到、也能备份。
/// 这里只放配置（最近项目、窗口偏好、日志），不放任何项目内容。删掉就回到首次运行的样子。
public enum AppPaths {
    public static let directoryName = ".agentidea"

    /// `~/.agentidea/`
    public static var configurationDirectory: URL {
        homeDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `~/.agentidea/logs/`
    public static var logDirectory: URL {
        configurationDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// `~/.agentidea/recent.json`：最近打开的项目。
    public static var recentProjectsFile: URL {
        configurationDirectory.appendingPathComponent("recent.json")
    }

    /// `~/.agentidea/run/`：「在终端中运行」生成的包装脚本。
    public static var runDirectory: URL {
        configurationDirectory.appendingPathComponent("run", isDirectory: true)
    }

    /// `~/.agentidea/github_token`：检查更新时访问私有仓库用的 token（可选）。
    public static var gitHubTokenFile: URL {
        configurationDirectory.appendingPathComponent("github_token")
    }

    /// 用 `NSHomeDirectory()` 而不是 `FileManager.homeDirectoryForCurrentUser`：
    /// 应用一旦进了沙箱后者会给出容器内的假家目录。本应用没开沙箱，写死前者让这条不随打包方式漂移。
    static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }
}
