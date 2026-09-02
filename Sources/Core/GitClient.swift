import Foundation

/// 用系统 git 命令操作仓库。
///
/// 读：仓库根、status、diff。写只有三类，都是用户在界面上明确点出来的：
/// 提交（`add` + `commit --only`）、推送、回滚（`restore` / `rm`）。除此之外不碰仓库。
public struct GitClient: Sendable {
    public static let searchPaths = ["/usr/local/bin/git", "/opt/homebrew/bin/git", "/usr/bin/git"]

    /// git 的空树对象。没有任何提交的仓库拿它当 HEAD 来算 diff。
    public static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    public let executable: URL
    private let runner: CommandRunning

    public init(executable: URL, runner: CommandRunning = ShellCommand()) {
        self.executable = executable
        self.runner = runner
    }

    /// 找本机的 git。找不到时返回 nil——没有 git 也要能当纯文件浏览器用。
    public static func locate() -> GitClient? {
        ExecutableLocator.locate(searchPaths).map { GitClient(executable: $0) }
    }

    /// 传给 git 的环境。
    ///
    /// `GIT_OPTIONAL_LOCKS=0`：`git status` 默认会顺手刷新索引并写 `.git/index`，
    /// 而我们正监听着这个目录——那一笔写入会再触发一次刷新，循环不止。
    /// `LC_ALL=C`：错误信息与输出格式固定为英文，解析不受用户语言影响。
    /// 底子是登录 shell 的环境（见 `LoginShellEnvironment`），push 要靠里面的 SSH_AUTH_SOCK 和 PATH。
    public static var environment: [String: String] {
        var environment = LoginShellEnvironment.current
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        // 别让 git 在没有终端的地方停下来等密码；要凭据就直接失败，错误会显示在界面上。
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = environment["GIT_ASKPASS"] ?? "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        return environment
    }

    private func run(_ arguments: [String], in directory: URL, acceptable: Set<Int32> = [0]) async throws -> ShellOutput {
        try await runner.runChecked(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            environment: Self.environment,
            acceptableStatuses: acceptable
        )
    }

    /// 这个目录属于哪个仓库。不在仓库里返回 nil。
    public func repositoryRoot(containing directory: URL) async -> URL? {
        guard let output = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 分支 + 全部变更 + 被忽略的路径。
    ///
    /// `--untracked-files=all` 让未跟踪目录里的文件逐个列出（变更列表要一个个看）；
    /// `--ignored=matching` 则只列匹配忽略规则的那一层（`node_modules/` 一条，不展开里面几万个文件）。
    public func snapshot(repositoryRoot: URL) async throws -> GitSnapshot {
        let output = try await run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"],
            in: repositoryRoot
        )
        return GitStatusParser.parse(output.standardOutput)
    }

    /// HEAD 存在吗（有没有过提交）。
    public func hasHead(repositoryRoot: URL) async -> Bool {
        (try? await run(["rev-parse", "--verify", "-q", "HEAD"], in: repositoryRoot)) != nil
    }

    /// 一条变更的 diff 原文（unified 格式，3 行上下文）。
    ///
    /// - 未跟踪文件：跟 `/dev/null` 比，整个文件算新增。`--no-index` 有差异时退出码是 1，要接受。
    /// - 其它：工作区对比 HEAD（暂存 + 未暂存合在一起，用户关心的是「Agent 改了什么」）。
    /// - 仓库还没有提交：对比空树。
    public func diff(change: GitChange, repositoryRoot: URL, ignoreWhitespace: Bool = false) async throws -> String {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames"]
        if ignoreWhitespace { arguments.append("-w") }

        if change.kind == .untracked {
            let absolute = repositoryRoot.appendingPathComponent(change.path).path
            arguments += ["--no-index", "--", "/dev/null", absolute]
            let output = try await run(arguments, in: repositoryRoot, acceptable: [0, 1])
            return output.text
        }

        let base = await hasHead(repositoryRoot: repositoryRoot) ? "HEAD" : Self.emptyTree
        arguments.append(base)
        arguments.append("--")
        arguments.append(change.path)
        if let original = change.originalPath { arguments.append(original) }
        let output = try await run(arguments, in: repositoryRoot, acceptable: [0, 1])
        return output.text
    }

    // MARK: - 提交历史

    /// 当前分支的提交，新的在前。`skip` 用来翻页。仓库还没有提交时返回空数组。
    public func log(repositoryRoot: URL, limit: Int, skip: Int = 0) async throws -> [GitCommit] {
        // 只有第一页需要先确认有 HEAD（没有提交时 git log 会报错）；翻页时第一页已经证明有了
        if skip == 0, !(await hasHead(repositoryRoot: repositoryRoot)) { return [] }
        var arguments = ["log", "-z", "--format=" + GitLogParser.format, "-n", String(limit)]
        if skip > 0 { arguments += ["--skip", String(skip)] }
        let output = try await run(arguments, in: repositoryRoot)
        return GitLogParser.parse(output.standardOutput)
    }

    /// 一次提交改了哪些文件：对比它的第一个父提交（根提交对比空树；合并提交看的是相对主线的变化）。
    public func changedFiles(in commit: GitCommit, repositoryRoot: URL) async throws -> [GitChange] {
        let output = try await run(["diff", "--name-status", "-z", "--find-renames", commit.diffBase, commit.hash], in: repositoryRoot)
        return GitNameStatusParser.parse(output.standardOutput)
    }

    /// 某次提交里一个文件的 diff（相对第一个父提交）。
    public func diff(change: GitChange, in commit: GitCommit, repositoryRoot: URL) async throws -> String {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", commit.diffBase, commit.hash, "--", change.path]
        if let original = change.originalPath { arguments.append(original) }
        return try await run(arguments, in: repositoryRoot, acceptable: [0, 1]).text
    }

    // MARK: - 写操作（提交与推送）

    /// 提交结果。
    public struct CommitResult: Equatable, Sendable {
        public let shortHash: String
        public let fileCount: Int

        public init(shortHash: String, fileCount: Int) {
            self.shortHash = shortHash
            self.fileCount = fileCount
        }
    }

    /// 把选中的路径暂存并提交。
    ///
    /// 分两步：`add -A -- <paths>` 让新增、修改、删除都进索引；再 `commit --only -- <paths>`，
    /// 只提交这些路径——用户之前在终端里 `git add` 过的别的东西不会被顺手带进去。
    public func commit(paths: [String], message: String, repositoryRoot: URL) async throws -> CommitResult {
        precondition(!paths.isEmpty, "没有要提交的路径")
        let unique = Array(Set(paths)).sorted()
        _ = try await run(["add", "-A", "--"] + unique, in: repositoryRoot)
        _ = try await run(["commit", "--quiet", "--only", "-m", message, "--"] + unique, in: repositoryRoot)
        let hash = try await run(["rev-parse", "--short", "HEAD"], in: repositoryRoot).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitResult(shortHash: hash, fileCount: unique.count)
    }

    /// 回滚：把这些路径恢复到 HEAD 的样子（索引与工作区一起）。重命名要把新旧路径都传进来。
    public func restoreToHead(paths: [String], repositoryRoot: URL) async throws {
        precondition(!paths.isEmpty)
        _ = try await run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + Array(Set(paths)).sorted(), in: repositoryRoot)
    }

    /// 回滚一个「新增」（在索引里、不在 HEAD 里）的文件：从索引和工作区一起删掉。IDEA 对 Added 的回滚也是删文件。
    public func removeAdded(path: String, repositoryRoot: URL) async throws {
        _ = try await run(["rm", "-f", "-q", "--", path], in: repositoryRoot)
    }

    /// 推送当前分支。没有上游的话建上游（`-u origin HEAD`）。返回 git 的输出（进度在 stderr 里）。
    public func push(repositoryRoot: URL, hasUpstream: Bool) async throws -> String {
        let arguments = hasUpstream ? ["push", "--porcelain"] : ["push", "--porcelain", "-u", "origin", "HEAD"]
        let output = try await run(arguments, in: repositoryRoot)
        let text = (output.text + "\n" + output.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}
