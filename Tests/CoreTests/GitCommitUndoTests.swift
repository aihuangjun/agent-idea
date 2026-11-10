import Core
import Foundation
import Testing
import TestSupport

// MARK: - 纯逻辑

private let record = GitCommitRecord(head: "new", previousHead: "old", branch: "main", message: "修好了\n\n正文", indexTreeAfterUndo: "tree1")

@Test func commitUndoChecksHeadBranchOperationAndRemote() {
    let ok = GitCommitUndo.State(head: "new", branch: "main")
    #expect(GitCommitUndo.undoProblem(record, state: ok) == nil)
    // 之后又有提交 / rebase 过 / 切到别的提交上
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "newer", branch: "main")) == .headMoved)
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: nil, branch: "main")) == .headMoved)
    // 同一个提交、换了分支（switch -c）
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: "feature")) == .branchChanged)
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: nil)) == .branchChanged)
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: "main", operation: .merge)) == .operationInProgress(.merge))
    // 推送过的：远程跟踪分支上有它，或者本会话推送成功过它
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: "main", isOnRemote: true)) == .pushed)
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: "main", wasPushed: true)) == .pushed)
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: "main", isBusy: true)) == .busy)
    // 「提交并推送」的推送还在跑：还查不出推送过，也不能撤
    let pushing = GitCommitRecord(head: "new", previousHead: "old", branch: "main", message: "m", pushRequested: true)
    #expect(GitCommitUndo.undoProblem(pushing, state: .init(head: "new", branch: "main", isPushing: true)) == .pushing)
    #expect(GitCommitUndo.undoProblem(record, state: .init(head: "new", branch: "main", isPushing: true)) == nil, "别的推送不挡普通提交的撤销")
    #expect(GitCommitUndo.undoProblem(pushing, state: ok) == nil, "推送失败了的照样能撤")
    #expect(GitCommitUndoProblem.pushed.message.contains("强制推送"))
}

@Test func commitRedoRequiresUntouchedIndex() {
    let ok = GitCommitUndo.State(head: "old", branch: "main", indexTree: "tree1")
    #expect(GitCommitUndo.redoProblem(record, state: ok) == nil)
    #expect(GitCommitUndo.redoProblem(record, state: .init(head: "new", branch: "main", indexTree: "tree1")) == .headMoved)
    #expect(GitCommitUndo.redoProblem(record, state: .init(head: "old", branch: "other", indexTree: "tree1")) == .branchChanged)
    #expect(GitCommitUndo.redoProblem(record, state: .init(head: "old", branch: "main", operation: .rebase, indexTree: "tree1")) == .operationInProgress(.rebase))
    // 撤销之后动过暂存区；有冲突写不出树
    #expect(GitCommitUndo.redoProblem(record, state: .init(head: "old", branch: "main", indexTree: "tree2")) == .indexChanged)
    #expect(GitCommitUndo.redoProblem(record, state: .init(head: "old", branch: "main", indexTree: nil)) == .indexChanged)
    var unknown = record
    unknown.indexTreeAfterUndo = nil
    #expect(GitCommitUndo.redoProblem(unknown, state: ok) == .indexChanged, "撤销时没记下树就不重做")
    // 首个提交：撤销之后又回到没有 HEAD
    let first = GitCommitRecord(head: "new", previousHead: nil, branch: "main", message: "m", indexTreeAfterUndo: "tree1")
    #expect(GitCommitUndo.redoProblem(first, state: .init(head: nil, branch: "main", indexTree: "tree1")) == nil)
    #expect(GitCommitUndo.redoProblem(first, state: .init(head: "x", branch: "main", indexTree: "tree1")) == .headMoved)
}

@Test func commitUndoArguments() {
    #expect(GitCommitUndo.undoArguments(record) == ["reset", "--soft", "old"])
    #expect(GitCommitUndo.redoArguments(record) == ["reset", "--soft", "new"])
    // 首个提交：删掉分支引用 / 重新建出来，都带旧值（原子的「还是它才动」）
    let first = GitCommitRecord(head: "new", previousHead: nil, branch: "main", message: "m")
    #expect(GitCommitUndo.undoArguments(first) == ["update-ref", "-m", "agentidea: undo commit", "-d", "HEAD", "new"])
    #expect(GitCommitUndo.redoArguments(first) == ["update-ref", "-m", "agentidea: redo commit", "HEAD", "new", ""])
    #expect(record.subject == "修好了" && record.shortHash == "new")
}

@Test func historyUndoOnlyForSingleParentHeadOnBranch() {
    func commit(_ hash: String, parents: [String], body: String = "") -> GitCommit {
        GitCommit(hash: hash, shortHash: String(hash.prefix(7)), parents: parents, authorName: "", authorEmail: "", authorDate: Date(), subject: "主题", body: body)
    }
    let branch = GitBranch(name: "main", headOID: "h")
    #expect(GitCommitUndo.historyProblem(for: commit("h", parents: ["p"]), head: "h", branch: branch) == nil)
    #expect(GitCommitUndo.historyProblem(for: commit("x", parents: ["p"]), head: "h", branch: branch) == .headMoved)
    #expect(GitCommitUndo.historyProblem(for: commit("h", parents: ["p"]), head: "", branch: branch) == .headMoved)
    #expect(GitCommitUndo.historyProblem(for: commit("h", parents: []), head: "h", branch: branch) == .rootCommit)
    #expect(GitCommitUndo.historyProblem(for: commit("h", parents: ["p", "q"]), head: "h", branch: branch) == .mergeCommit)
    #expect(GitCommitUndo.historyProblem(for: commit("h", parents: ["p"]), head: "h", branch: GitBranch(name: "h", isDetached: true, headOID: "h")) == .detached)
    let made = GitCommitUndo.record(for: commit("h", parents: ["p"], body: "正文"), branch: "main")
    #expect(made == GitCommitRecord(head: "h", previousHead: "p", branch: "main", message: "主题\n\n正文"))
    #expect(GitCommitUndo.record(for: commit("h", parents: ["p"]), branch: nil).message == "主题")
}

@Test func undoRouteFallsThroughEmptyTextControl() {
    #expect(UndoRoute.route(focusInTextControl: true, textControlCanAct: true, focusInWebView: false) == .textControl)
    #expect(UndoRoute.route(focusInTextControl: true, textControlCanAct: true, textControlYieldsToCommit: true, focusInWebView: false) == .textControl,
            "提交信息框里有字可撤：先撤字")
    // 提交完输入框清空、撤销栈也清了，栈顶是那次提交：⌘Z 撤的是它
    #expect(UndoRoute.route(focusInTextControl: true, textControlCanAct: false, textControlYieldsToCommit: true, focusInWebView: false) == .fileOperation)
    // 别的文本控件（搜索框）没东西可撤：什么都不做，不在背后撤掉文件操作
    #expect(UndoRoute.route(focusInTextControl: true, textControlCanAct: false, focusInWebView: false) == .textControl)
    #expect(UndoRoute.route(focusInTextControl: false, textControlCanAct: false, focusInWebView: true) == .editor)
    #expect(UndoRoute.route(focusInTextControl: false, textControlCanAct: false, focusInWebView: false) == .fileOperation)
}

// MARK: - 真 git

private func runGit(_ git: GitClient, _ args: [String], in directory: URL, acceptable: Set<Int32> = [0]) async throws -> String {
    try await ShellCommand().runChecked(executable: git.executable, arguments: args, currentDirectory: directory,
                                        environment: ["GIT_CONFIG_NOSYSTEM": "1", "HOME": directory.path, "PATH": "/usr/bin:/bin"],
                                        acceptableStatuses: acceptable).text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 照会话的流程走一遍：取状态 → 核对 → reset --soft → 记下索引的树 → 重做前比对。
private func state(_ git: GitClient, _ repo: URL, remoteOf hash: String? = nil) async throws -> GitCommitUndo.State {
    var state = GitCommitUndo.State(head: try await git.headCommit(repositoryRoot: repo), branch: try await git.symbolicBranch(repositoryRoot: repo),
                                    operation: await git.operationInProgress(repositoryRoot: repo))
    if let hash { state.isOnRemote = try await git.isCommitOnRemote(hash, repositoryRoot: repo) }
    state.indexTree = await git.indexTree(repositoryRoot: repo)
    return state
}

@Test func realGitUndoAndRedoCommit() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { repo in
        _ = try await runGit(git, ["init", "-q", "-b", "main"], in: repo)
        _ = try await runGit(git, ["config", "user.email", "t@example.com"], in: repo)
        _ = try await runGit(git, ["config", "user.name", "t"], in: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // 首个提交：撤销后回到「还没有提交」，索引原样（a.txt 还是新增），重做再建回来
        #expect(try await git.headCommit(repositoryRoot: repo) == nil)
        let firstBefore = try await git.headCommit(repositoryRoot: repo)
        let first = try await git.commit(paths: ["a.txt"], message: "init", repositoryRoot: repo)
        var firstRecord = GitCommitRecord(head: first.hash, previousHead: firstBefore, branch: try await git.symbolicBranch(repositoryRoot: repo), message: "init")
        #expect(firstRecord.branch == "main" && first.hash.count == 40)
        #expect(GitCommitUndo.undoProblem(firstRecord, state: try await state(git, repo, remoteOf: first.hash)) == nil)
        try await git.undoCommit(firstRecord, repositoryRoot: repo)
        #expect(try await git.headCommit(repositoryRoot: repo) == nil)
        #expect(try await git.symbolicBranch(repositoryRoot: repo) == "main", "没有提交的分支也还有名字")
        #expect(try await git.snapshot(repositoryRoot: repo).changes.map { "\($0.path):\($0.kind)" } == ["a.txt:added"])
        firstRecord.indexTreeAfterUndo = await git.indexTree(repositoryRoot: repo)
        #expect(GitCommitUndo.redoProblem(firstRecord, state: try await state(git, repo)) == nil)
        try await git.redoCommit(firstRecord, repositoryRoot: repo)
        #expect(try await git.headCommit(repositoryRoot: repo) == first.hash)

        // 普通提交，索引里另有终端 add 过的 staged.txt（--only 不带它）：提交的树 ≠ 索引的树，重做照样要能做
        try "s\n".write(to: repo.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        _ = try await runGit(git, ["add", "staged.txt"], in: repo)
        try "a\nb\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let before = try await git.headCommit(repositoryRoot: repo)
        let second = try await git.commit(paths: ["a.txt"], message: "改 a\n\n正文", repositoryRoot: repo)
        var secondRecord = GitCommitRecord(head: second.hash, previousHead: before, branch: "main", message: "改 a\n\n正文")
        #expect(try await git.snapshot(repositoryRoot: repo).changes.map(\.path) == ["staged.txt"])
        #expect(GitCommitUndo.undoProblem(secondRecord, state: try await state(git, repo, remoteOf: second.hash)) == nil)
        try await git.undoCommit(secondRecord, repositoryRoot: repo)
        #expect(try await git.headCommit(repositoryRoot: repo) == first.hash)
        // 改动回来了，在暂存区里；工作区一字没动
        let undone = Dictionary(uniqueKeysWithValues: try await git.snapshot(repositoryRoot: repo).changes.map { ($0.path, $0.kind) })
        #expect(undone["a.txt"] == .modified && undone["staged.txt"] == .added)
        #expect(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8) == "a\nb\n")
        secondRecord.indexTreeAfterUndo = await git.indexTree(repositoryRoot: repo)
        #expect(GitCommitUndo.redoProblem(secondRecord, state: try await state(git, repo)) == nil)
        // 撤销之后又动了暂存区：不重做；放回原样又可以
        try "t\n".write(to: repo.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
        _ = try await runGit(git, ["add", "t.txt"], in: repo)
        #expect(GitCommitUndo.redoProblem(secondRecord, state: try await state(git, repo)) == .indexChanged)
        _ = try await runGit(git, ["rm", "-q", "--cached", "t.txt"], in: repo)
        #expect(GitCommitUndo.redoProblem(secondRecord, state: try await state(git, repo)) == nil)
        try await git.redoCommit(secondRecord, repositoryRoot: repo)
        #expect(try await git.headCommit(repositoryRoot: repo) == second.hash)
        #expect(try await git.snapshot(repositoryRoot: repo).changes.map(\.path).sorted() == ["staged.txt", "t.txt"])

        // amend 之后撤销：被修改的旧提交原样回来，amend 带进去的改动回到暂存区
        try "a\nb\nc\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let amendBefore = try await git.headCommit(repositoryRoot: repo)
        let amended = try await git.commit(paths: ["a.txt"], message: "改 a（amend）", amend: true, repositoryRoot: repo)
        let amendRecord = GitCommitRecord(head: amended.hash, previousHead: amendBefore, branch: "main", message: "改 a（amend）", isAmend: true)
        #expect(amendBefore == second.hash && amended.hash != second.hash)
        try await git.undoCommit(amendRecord, repositoryRoot: repo)
        #expect(try await git.headCommit(repositoryRoot: repo) == second.hash)
        #expect(try await git.headMessage(repositoryRoot: repo) == "改 a\n\n正文")
        #expect(try await git.snapshot(repositoryRoot: repo).changes.first { $0.path == "a.txt" }?.kind == .modified)

        // HEAD 挪走了（Agent 又提交了一次）：不撤
        _ = try await runGit(git, ["commit", "-q", "-m", "agent", "--", "a.txt"], in: repo)
        #expect(GitCommitUndo.undoProblem(secondRecord, state: try await state(git, repo, remoteOf: second.hash)) == .headMoved)

        // 合并到一半：认得出来
        let mergeHead = try await runGit(git, ["rev-parse", "--git-path", "MERGE_HEAD"], in: repo)
        try (second.hash + "\n").write(to: repo.appendingPathComponent(mergeHead), atomically: true, encoding: .utf8)
        #expect(await git.operationInProgress(repositoryRoot: repo) == .merge)
        try FileManager.default.removeItem(at: repo.appendingPathComponent(mergeHead))
        #expect(await git.operationInProgress(repositoryRoot: repo) == nil)
    }
}

/// 推送过的提交：本地 bare 仓库当远程，推上去之后 `branch -r --contains` 认得出来，撤销被拒。
@Test func realGitRefusesToUndoPushedCommit() async throws {
    guard let git = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let remote = directory.appendingPathComponent("remote.git")
        let repo = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await runGit(git, ["init", "-q", "--bare", "-b", "main", remote.path], in: directory)
        _ = try await runGit(git, ["init", "-q", "-b", "main"], in: repo)
        _ = try await runGit(git, ["config", "user.email", "t@example.com"], in: repo)
        _ = try await runGit(git, ["config", "user.name", "t"], in: repo)
        _ = try await runGit(git, ["remote", "add", "origin", remote.path], in: repo)
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.commit(paths: ["a.txt"], message: "init", repositoryRoot: repo)
        try "b".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let before = try await git.headCommit(repositoryRoot: repo)
        let result = try await git.commit(paths: ["a.txt"], message: "b", repositoryRoot: repo)
        let record = GitCommitRecord(head: result.hash, previousHead: before, branch: "main", message: "b")
        #expect(GitCommitUndo.undoProblem(record, state: try await state(git, repo, remoteOf: result.hash)) == nil, "还没推送")
        _ = try await runGit(git, ["push", "-q", "-u", "origin", "main"], in: repo)
        #expect(GitCommitUndo.undoProblem(record, state: try await state(git, repo, remoteOf: result.hash)) == .pushed)
    }
}
