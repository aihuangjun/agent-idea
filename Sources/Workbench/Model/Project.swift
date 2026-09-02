import Foundation

/// 当前打开的项目（工作区）。
public struct Project: Equatable, Sendable {
    /// 项目根，**已解析符号链接**（`/var/…` → `/private/var/…`）。
    ///
    /// 树上的节点、FSEvents 报上来的路径、`git rev-parse` 给的仓库根全是解析过的真实路径，
    /// 根不解析的话展开状态、选中项、git 着色三处的路径对不上，症状是「点了目录不展开」。
    public let root: URL
    /// 用户选的那个名字：根本身是符号链接时，显示链接名而不是目标名。
    public let name: String
    /// 所属 git 仓库的根。项目目录可能是仓库的子目录；不在仓库里为 nil。
    public var repositoryRoot: URL? {
        didSet { repositoryRoot = repositoryRoot?.resolvingSymlinksInPath().standardizedFileURL }
    }

    public init(root: URL, repositoryRoot: URL? = nil) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.name = root.lastPathComponent
        self.repositoryRoot = repositoryRoot?.resolvingSymlinksInPath().standardizedFileURL
    }

    /// 一个绝对路径相对仓库根的形式（git 的口径，`/` 分隔、无前导斜杠）。不在仓库里返回 nil。
    public func repositoryRelativePath(of url: URL) -> String? {
        guard let repositoryRoot else { return nil }
        let rootPath = repositoryRoot.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// 反过来：仓库相对路径 → 绝对 URL。
    public func url(forRepositoryPath relative: String) -> URL? {
        repositoryRoot?.appendingPathComponent(relative)
    }

    /// 给面包屑用：相对项目根的路径段。
    public func projectRelativeComponents(of url: URL) -> [String] {
        let rootPath = root.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return [url.lastPathComponent] }
        return String(path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
    }
}
