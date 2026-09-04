import Foundation

/// 用系统 git 命令操作仓库。
///
/// 读：仓库根、status、diff、log。写只有几类，都是用户在界面上明确点出来的：
/// 提交（`add` / `rm --cached` + `commit --only`）、推送、回滚工作区变更（`restore` / `rm`）、
/// 反向打回历史提交里的一个变更（`apply --reverse`）。除此之外不碰仓库。
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

    /// 一个文件在 HEAD 里的内容（编辑器的 gutter 变更标记拿它当基线）。HEAD 里没有这个文件（未跟踪、新增、还没提交）返回 nil。
    public func headContent(path: String, repositoryRoot: URL) async -> String? {
        guard let output = try? await run(["show", "HEAD:" + path], in: repositoryRoot) else { return nil }
        // 与读工作区文件同一套猜编码（GB18030 的老文件也要能比），二进制的没有基线
        if case .text(let text, _, _) = TextFileLoader.decode(output.standardOutput) { return text }
        return nil
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

    /// 回滚某次提交里的一个文件变更（IDEA 历史里的 Revert Selected Changes）：
    /// 取出那次提交对这个文件的补丁，反向打到工作区。新增的文件会被删掉，删掉的会回来，改动会撤销。
    ///
    /// 只动工作区、不动索引，也不产生提交——回滚完就是一条普通的工作区变更，用户看过 diff 再决定提不提交。
    /// 工作区在那之后又改过同一处的话 `apply` 会失败，错误原样显示。
    public func revert(change: GitChange, in commit: GitCommit, repositoryRoot: URL) async throws {
        var arguments = ["diff", "--binary", "--no-color", "--no-ext-diff", "--find-renames", commit.diffBase, commit.hash, "--", change.path]
        if let original = change.originalPath { arguments.append(original) }
        let patch = try await run(arguments, in: repositoryRoot, acceptable: [0, 1]).standardOutput
        guard !patch.isEmpty else { throw GitRevertError.nothingToRevert }
        // apply 只认文件或 stdin，我们不开 stdin，写个临时文件
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentidea-revert-\(UUID().uuidString).patch")
        try patch.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(["apply", "--reverse", "--whitespace=nowarn", file.path], in: repositoryRoot)
    }

    public enum GitRevertError: Error, LocalizedError, Equatable {
        /// 这次提交对这个文件没有可打回去的补丁（比如只改了模式、或列表过期了）。
        case nothingToRevert

        public var errorDescription: String? { "这次提交没有改这个文件，没有可回滚的内容" }
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
    /// 先把路径按「磁盘上还在不在」分两拨暂存，再 `commit --only -- <paths>` 只提交这些路径——
    /// 用户之前在终端里 `git add` 过的别的东西不会被顺手带进去。
    ///
    /// - 磁盘上有的：`add -A --`，新增、修改都进索引。
    /// - 磁盘上没有的（工作区删除、已暂存的删除、重命名的原路径）：`rm --cached --ignore-unmatch --`。
    ///   不能一股脑交给 `add -A`：pathspec 既不在磁盘也不在索引里时（Agent 已经 `git mv` / `git rm` 过），
    ///   `add` 会报 `pathspec '…' did not match any files` 直接失败；`rm --ignore-unmatch` 对这种情况静默跳过，
    ///   对「删了文件还没暂存」的则正好把删除记进索引。
    public func commit(paths: [String], message: String, repositoryRoot: URL) async throws -> CommitResult {
        precondition(!paths.isEmpty, "没有要提交的路径")
        let unique = Array(Set(paths)).sorted()
        let (present, missing) = Self.partitionByPresence(unique, repositoryRoot: repositoryRoot)
        if !present.isEmpty {
            _ = try await run(["add", "-A", "--"] + present, in: repositoryRoot)
        }
        if !missing.isEmpty {
            _ = try await run(["rm", "--cached", "--ignore-unmatch", "--quiet", "--"] + missing, in: repositoryRoot)
        }
        _ = try await run(["commit", "--quiet", "--only", "-m", message, "--"] + unique, in: repositoryRoot)
        let hash = try await run(["rev-parse", "--short", "HEAD"], in: repositoryRoot).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitResult(shortHash: hash, fileCount: unique.count)
    }

    /// 把路径分成「磁盘上有」与「磁盘上没有」两组，顺序保持。
    ///
    /// 用 `attributesOfItem`（lstat）而不是 `fileExists`：后者会跟着符号链接走，一个目标失效的链接会被当成不存在，
    /// 进了 `rm --cached` 那一组就把好端端的链接从索引里删了。
    static func partitionByPresence(_ paths: [String], repositoryRoot: URL, fileManager: FileManager = .default) -> (present: [String], missing: [String]) {
        var present: [String] = []
        var missing: [String] = []
        for path in paths {
            let absolute = repositoryRoot.appendingPathComponent(path).path
            if (try? fileManager.attributesOfItem(atPath: absolute)) != nil {
                present.append(path)
            } else {
                missing.append(path)
            }
        }
        return (present, missing)
    }

    /// 回滚：把这些路径恢复到 HEAD 的样子（索引与工作区一起）。重命名要把新旧路径都传进来。
    public func restoreToHead(paths: [String], repositoryRoot: URL) async throws {
        precondition(!paths.isEmpty)
        _ = try await run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + Array(Set(paths)).sorted(), in: repositoryRoot)
    }

    /// 重命名 / 移动一个已跟踪的文件或目录（`git mv`）：git 负责搬磁盘上的文件，索引里同步记成重命名，
    /// status 才会显示成一条「重命名」而不是「删除 + 未跟踪」。未跟踪的路径 git 会拒绝，调用方退回普通的搬文件。
    public func move(from oldPath: String, to newPath: String, repositoryRoot: URL) async throws {
        _ = try await run(["mv", "--", oldPath, newPath], in: repositoryRoot)
    }

    /// `git mv` 失败是不是「git 不认这个路径」——未跟踪的文件、里面没有已跟踪文件的目录，
    /// 以及不分大小写的文件系统上目录只改大小写（git 把目标当成已存在的目录、想搬进它自己，报 Invalid argument）。
    /// 这几种可以放心退回普通搬文件；别的（index.lock 被占、目标已存在）不能，否则文件搬了、索引没动。
    public static func refusedBecauseUntracked(_ error: Error) -> Bool {
        guard let error = error as? ShellCommandError else { return false }
        let message = error.message.lowercased()
        return message.contains("not under version control") || message.contains("source directory is empty") || message.contains("invalid argument")
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
