import Foundation

/// 用系统 git 命令操作仓库。
///
/// 读：仓库根、status、diff、log。写只有几类，都是用户在界面上明确点出来的：
/// 提交（`add` / `rm --cached` + `commit --only`）、推送、与远程同步（`fetch` + `rebase --autostash`）、
/// 回滚工作区变更（`restore` / `rm`）、反向打回历史提交里的一个变更（`apply --reverse`）。除此之外不碰仓库。
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

    /// `stallTimeout`：走网络的命令给，多少秒一个字节都没输出就当卡死停掉（见 `CommandRunning.run(…stallTimeout:)`）。
    private func run(_ arguments: [String], in directory: URL, acceptable: Set<Int32> = [0], stallTimeout: TimeInterval? = nil) async throws -> ShellOutput {
        try await runner.runChecked(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            environment: Self.environment,
            acceptableStatuses: acceptable,
            stallTimeout: stallTimeout
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

    /// 当前分支的提交，新的在前（按提交时间 `%ct`，与界面上显示的时间一致）。`skip` 用来翻页。仓库还没有提交时返回空数组。
    public func log(repositoryRoot: URL, limit: Int, skip: Int = 0) async throws -> [GitCommit] {
        // 只有第一页需要先确认有 HEAD（没有提交时 git log 会报错）；翻页时第一页已经证明有了
        if skip == 0, !(await hasHead(repositoryRoot: repositoryRoot)) { return [] }
        // --date-order：明确按提交时间排，且子提交永远排在父提交前面（拉回来的分支时间戳交错时不至于乱序）
        var arguments = ["log", "--date-order", "-z", "--format=" + GitLogParser.format, "-n", String(limit)]
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
        for batch in Self.batches(of: paths) {
            _ = try await run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + batch, in: repositoryRoot)
        }
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

    /// 回滚「新增」（在索引里、不在 HEAD 里）的文件：从索引和工作区一起删掉。IDEA 对 Added 的回滚也是删文件。
    public func removeAdded(paths: [String], repositoryRoot: URL) async throws {
        precondition(!paths.isEmpty)
        for batch in Self.batches(of: paths) {
            _ = try await run(["rm", "-f", "-q", "--"] + batch, in: repositoryRoot)
        }
    }

    /// 一个路径（文件或目录）下 git 还不认识的**文件**，逐个列出、不折成目录（`ls-files --others`）。
    ///
    /// `ignored` 为 false 时列的是未跟踪的（被 `.gitignore` 挡掉的不在里面），为 true 时反过来只列被忽略的。
    /// 已跟踪的文件一个都不会出现在结果里——所以拿它算出来的路径可以放心 `add`，也可以放心在撤销时从索引里撤下来，
    /// 不会连累目录里本来就跟踪着的文件。
    public func untrackedFiles(under paths: [String], ignored: Bool = false, repositoryRoot: URL) async throws -> [String] {
        precondition(!paths.isEmpty)
        // --ignored 必须配合 --exclude-standard（git 要求给出忽略规则的来源）
        var arguments = ["ls-files", "-z", "--others", "--exclude-standard"]
        if ignored { arguments.append("--ignored") }
        arguments += ["--"] + paths
        let output = try await run(arguments, in: repositoryRoot)
        let listed = String(decoding: output.standardOutput, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return Array(Set(listed)).sorted()
    }

    /// 把这些路径纳入版本管理（`git add`，IDEA 的 Add to VCS）。
    /// `force` 是给被 `.gitignore` 忽略的路径用的——不加 `-f` 时 git 直接拒绝整条命令（退出码 1，一个都不会加）。
    /// 别把 `force` 用在未跟踪的目录上：那会把目录里本该被忽略的东西（`node_modules` 之类）一起拖进来。
    public func add(paths: [String], force: Bool = false, repositoryRoot: URL) async throws {
        precondition(!paths.isEmpty)
        for batch in Self.batches(of: paths) {
            var arguments = ["add"]
            if force { arguments.append("--force") }
            arguments += ["--"] + batch
            _ = try await run(arguments, in: repositoryRoot)
        }
    }

    /// 把这些路径从索引里撤下来，工作区的文件不动（撤销「添加到 git」）：它们回到未跟踪 / 被忽略的样子。
    /// 只对刚加进来、HEAD 里还没有的文件用——已跟踪的文件这么做等于把它从版本管理里摘出去。
    public func unstage(paths: [String], repositoryRoot: URL) async throws {
        precondition(!paths.isEmpty)
        for batch in Self.batches(of: paths) {
            _ = try await run(["rm", "--cached", "--ignore-unmatch", "--quiet", "--"] + batch, in: repositoryRoot)
        }
    }

    /// 去重、排序，再切成几段跑：一个被忽略的目录（`node_modules`）底下几万个文件一次全塞进 argv 会超过系统上限
    /// （macOS 的 ARG_MAX 是 1MB），git 还没开始跑就 E2BIG 失败了。
    static func batches(of paths: [String], size: Int = 512) -> [[String]] {
        let unique = Array(Set(paths)).sorted()
        return stride(from: 0, to: unique.count, by: size).map { Array(unique[$0..<min($0 + size, unique.count)]) }
    }

    /// 把这些路径在工作区里的样子记进索引（`add -A`：新增、修改、删除都记）。撤销「回滚」时用来把新增 / 重命名的状态放回去，
    /// 否则写回来的文件在 git 眼里只是个未跟踪文件。
    public func stage(paths: [String], repositoryRoot: URL) async throws {
        precondition(!paths.isEmpty)
        _ = try await run(["add", "-A", "--"] + Array(Set(paths)).sorted(), in: repositoryRoot)
    }

    // MARK: - 与远程同步

    /// 当前分支跟踪的上游（`origin/main` 这种）。没有上游、游离 HEAD 时返回 nil。
    public func upstreamBranch(repositoryRoot: URL) async -> String? {
        guard let output = try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repositoryRoot) else { return nil }
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 当前分支名；游离 HEAD 时是 `HEAD`。
    public func currentBranch(repositoryRoot: URL) async -> String {
        let output = try? await run(["rev-parse", "--abbrev-ref", "HEAD"], in: repositoryRoot)
        let name = output?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "HEAD" : name
    }

    /// 网络命令连续多少秒没有任何输出算卡死。
    public static let networkStallTimeout: TimeInterval = 30

    /// 从远程取最新的引用。`--prune` 顺手清掉远端已经删掉的分支的本地跟踪引用。
    /// 不带 remote：git 自己按当前分支的配置挑（没配就是 origin）。
    ///
    /// 带看门狗：ssh 连不上（没连 VPN）、或者连上了却不来数据（网络抖动、代理半死）时 fetch 可以一直挂着——
    /// 等它的同步按钮就一直灰着、转着，用户不知道为什么点不了（1.2.0 前报过）。连续 `networkStallTimeout` 秒没动静就停掉报错。
    /// `--progress`：不是终端时 git 默认不报进度，拉得慢的大仓库会一直安静，被看门狗误当成卡死。
    public func fetch(repositoryRoot: URL) async throws {
        do {
            _ = try await run(["fetch", "--prune", "--progress"], in: repositoryRoot, stallTimeout: Self.networkStallTimeout)
        } catch let stalled as ShellCommandStalled {
            throw GitSyncError.fetchStalled(seconds: Int(stalled.seconds))
        } catch let failure as ShellCommandError {
            // 出错时 stderr 里前面是一大串进度行，给人看的只该是真正的错误
            throw ShellCommandError(command: failure.command, status: failure.status, message: GitProgress.removingProgress(failure.message))
        }
    }

    /// 本地相对上游落后 / 领先几个提交。看不懂 git 的输出就报错——把它当成 0/0 会静悄悄地跳过 rebase，
    /// 界面显示「已经是最新的」而其实还落后着。
    public func divergence(from upstream: String, repositoryRoot: URL) async throws -> (behind: Int, ahead: Int) {
        let output = try await run(["rev-list", "--left-right", "--count", upstream + "...HEAD"], in: repositoryRoot)
        guard let counts = GitRevListCount.parse(output.text) else {
            throw GitSyncError.unreadableDivergence(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return counts
    }

    /// 仓库是不是正停在一次 rebase 中途。问 git 要路径（`--git-path`）而不是自己拼 `.git/`：
    /// worktree、`.git` 是文件的情形拼不对。
    public func isRebaseInProgress(repositoryRoot: URL) async -> Bool {
        for name in ["rebase-merge", "rebase-apply"] {
            guard let output = try? await run(["rev-parse", "--git-path", name], in: repositoryRoot) else { continue }
            let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repositoryRoot.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    /// 与远程同步（IDEA 的 Update Project）：`fetch` 之后把上游的新提交 rebase 到本地分支下面。
    ///
    /// - 仓库已经停在一次 rebase 中途（用户自己在终端里开的）时直接拒绝：出错时我们会 `--abort`，
    ///   那会把他解了一半的冲突一起扔掉。
    /// - 上游没有新提交就不跑 rebase，本地一动不动。
    /// - 工作区有没提交的改动时靠 `--autostash` 收起再放回来，不用先手动 stash。放不回去时 git 只当警告
    ///   （退出码还是 0），改动留在 stash 里、工作区带冲突标记，这种情况要在结果里说明白。
    /// - rebase 没走完一律 `--abort` 回到同步前的样子再报错：这个应用没有解冲突的界面，
    ///   把仓库停在 rebase 中途只会让用户更难办。只收拾这一次自己留下的：进来时确认过没有别的 rebase 在跑。
    public func syncWithRemote(repositoryRoot: URL) async throws -> GitSyncResult {
        guard await hasHead(repositoryRoot: repositoryRoot) else { throw GitSyncError.unborn }
        guard !(await isRebaseInProgress(repositoryRoot: repositoryRoot)) else { throw GitSyncError.rebaseInProgress }
        guard let upstream = await upstreamBranch(repositoryRoot: repositoryRoot) else {
            throw GitSyncError.noUpstream(branch: await currentBranch(repositoryRoot: repositoryRoot))
        }
        try await fetch(repositoryRoot: repositoryRoot)
        let counts = try await divergence(from: upstream, repositoryRoot: repositoryRoot)
        guard counts.behind > 0 else {
            return GitSyncResult(upstream: upstream, pulled: 0, replayed: counts.ahead)
        }
        do {
            let output = try await run(["rebase", "--autostash", upstream], in: repositoryRoot)
            let said = output.text + "\n" + output.standardError
            return GitSyncResult(upstream: upstream, pulled: counts.behind, replayed: counts.ahead,
                                 autostashConflicted: GitSyncResult.mentionsAutostashConflict(said))
        } catch is CancellationError {
            // 取消是调用方的事（关项目、退出），不是失败；rebase 被 SIGTERM 打断的话 git 自己会收尾
            throw CancellationError()
        } catch {
            // rebase 在建起中间状态之前就退出的（上游引用没了这类）什么都没动，不用 abort，也不该吓唬用户
            var recovered = true
            if await isRebaseInProgress(repositoryRoot: repositoryRoot) {
                recovered = (try? await run(["rebase", "--abort"], in: repositoryRoot)) != nil
            }
            throw GitSyncError.rebaseFailed(message: error.userFacingDescription, recovered: recovered)
        }
    }

    // MARK: - 推送

    /// 推送连续多少秒没有任何输出算卡死。比 fetch 宽：推完之后远端还要跑钩子（GitLab 的检查、提示建 MR 那几行），那一段是安静的。
    public static let pushStallTimeout: TimeInterval = 60

    /// 推送当前分支。没有上游的话建上游（`-u <remote> HEAD`，`remote` 默认 origin）。返回 git 的输出（进度行已去掉）。
    ///
    /// 上游与本地分支**不同名**（从 origin/master 开出来、跟踪着 origin/master 的 feature 分支）、而 `git push` 又会推回拉取的那个远程时，
    /// 推到那个远程的**同名**分支：不带参数的 `git push` 在 `push.default=simple`（git 的默认）下会直接拒绝，而把 feature 分支推进 master
    /// 更不是用户要的。其余情况都照常 `git push`，由 git 按用户自己的配置决定推到哪（见 `remoteWhenPlainPushWouldBeRefused`）。
    /// 带看门狗、`--progress` 的理由与 `fetch` 一样。
    public func push(repositoryRoot: URL, hasUpstream: Bool, remote: String = "origin") async throws -> String {
        var arguments = ["push", "--porcelain", "--progress"]
        if !hasUpstream {
            arguments += ["-u", remote, "HEAD"]
        } else if let pullRemote = await remoteWhenPlainPushWouldBeRefused(repositoryRoot: repositoryRoot) {
            arguments += [pullRemote, "HEAD"]
        }
        do {
            let output = try await run(arguments, in: repositoryRoot, stallTimeout: Self.pushStallTimeout)
            return (output.text + "\n" + GitProgress.removingProgress(output.standardError)).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let stalled as ShellCommandStalled {
            throw GitSyncError.pushStalled(seconds: Int(stalled.seconds))
        } catch let failure as ShellCommandError {
            throw ShellCommandError(command: failure.command, status: failure.status, message: GitProgress.removingProgress(failure.message))
        }
    }

    /// 不带参数的 `git push` 会不会因为「上游不同名」被拒，会的话返回该推去的远程（拉取的那个），否则 nil（照常推）。
    ///
    /// 只在这几条同时成立时才插手：`push.default` 没设或是 `simple`（设成 upstream / current / matching 是用户自己的选择，
    /// upstream 就是要推进 master，不替他改）；推送的远程就是拉取的远程——fork 工作流里 `branch.<名>.pushRemote` /
    /// `remote.pushDefault` 指向自己的 fork 时，git 会按 current 推到 fork 的同名分支，那本来就是对的，别改成推进主仓库
    /// （1.2.1 发布前的 review 抓的）；上游确实不同名；不是游离 HEAD、读得到配置。
    func remoteWhenPlainPushWouldBeRefused(repositoryRoot: URL) async -> String? {
        let branch = await currentBranch(repositoryRoot: repositoryRoot)
        guard branch != "HEAD" else { return nil }
        func config(_ key: String) async -> String? {
            let value = (try? await run(["config", "--get", key], in: repositoryRoot))?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let merge = await config("branch.\(branch).merge"), merge != "refs/heads/" + branch,
              let pullRemote = await config("branch.\(branch).remote"), pullRemote != "." else { return nil }
        if let mode = await config("push.default"), mode != "simple" { return nil }
        var pushRemote = await config("branch.\(branch).pushRemote")
        if pushRemote == nil { pushRemote = await config("remote.pushDefault") }
        pushRemote = pushRemote ?? pullRemote
        return pushRemote == pullRemote ? pullRemote : nil
    }

    // MARK: - 分支

    /// 本地分支、远程跟踪分支、远程的默认分支（状态栏的分支弹窗，IDEA 的 Git Branches）。只看本地已知的引用，不联网。
    public func branches(repositoryRoot: URL) async throws -> GitBranchList {
        let remotes = (try? await run(["remote"], in: repositoryRoot))?.text
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        let refs = try await run(["for-each-ref", "--format=" + GitBranchList.forEachRefFormat, "refs/heads", "refs/remotes"], in: repositoryRoot).text
        var remoteHead: String?
        if let remote = remotes.contains("origin") ? "origin" : remotes.first,
           let output = try? await run(["symbolic-ref", "-q", "--short", "refs/remotes/\(remote)/HEAD"], in: repositoryRoot) {
            let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteHead = name.isEmpty ? nil : name
        }
        return GitBranchList.parse(refs, remotes: remotes, remoteHead: remoteHead)
    }

    /// 切到一个本地分支（`git switch`）。没提交的改动会被带过去；会被覆盖的话 git 拒绝，什么都不动。
    public func switchBranch(to name: String, repositoryRoot: URL) async throws {
        _ = try await run(["switch", name], in: repositoryRoot)
    }

    /// 新建分支并切过去。`startPoint` 是远程分支时 `track` 为 true：新分支跟踪它（git 自己的默认也是这样），
    /// 同步就从它拉——从 origin/master 开出来的分支，点同步就是把 master 上的新提交 rebase 进来。
    public func createBranch(_ name: String, from startPoint: String, track: Bool, repositoryRoot: URL) async throws {
        _ = try await run(["switch", "-c", name, track ? "--track" : "--no-track", startPoint], in: repositoryRoot)
    }

    /// 让当前分支跟踪一个远程分支（`git branch --set-upstream-to`）。只改配置，不动工作区与提交。
    public func setUpstream(_ upstream: String, repositoryRoot: URL) async throws {
        _ = try await run(["branch", "--set-upstream-to=" + upstream], in: repositoryRoot)
    }
}
