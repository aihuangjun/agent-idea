import Core
import Foundation
import Testing
import TestSupport

/// 历史列表的行序：新的在前。c4 → c3 → c2 → c1（根）。
private func commit(_ hash: String, parent: String?) -> GitCommit {
    GitCommit(hash: hash, shortHash: String(hash.prefix(7)), parents: parent.map { [$0] } ?? [], authorName: "a", authorEmail: "a@x",
              authorDate: Date(timeIntervalSince1970: 0), subject: hash, body: "")
}

private let commits = [
    commit("c4c4c4c4c4", parent: "c3c3c3c3c3"),
    commit("c3c3c3c3c3", parent: "c2c2c2c2c2"),
    commit("c2c2c2c2c2", parent: "c1c1c1c1c1"),
    commit("c1c1c1c1c1", parent: nil),
]

@Test func selectionMapsToOldestParentThroughNewest() throws {
    // 连续的一段：base = 最老那个的父提交，target = 最新那个；顺序与集合里的先后无关
    let range = try #require(GitCommitRange.selection(["c2c2c2c2c2", "c4c4c4c4c4", "c3c3c3c3c3"], in: commits))
    #expect(range.base == "c1c1c1c1c1")
    #expect(range.target == "c4c4c4c4c4")
    #expect(range.commitCount == 3 && range.skippedCount == 0)
    #expect(range.kind == .commits(oldest: "c2c2c2c", newest: "c4c4c4c"))
    #expect(range.id == "c1c1c1c1c1..c4c4c4c4c4")
    #expect(range.note == nil)

    // 选到了根提交：base 是空树
    let toRoot = try #require(GitCommitRange.selection(["c1c1c1c1c1", "c2c2c2c2c2"], in: commits))
    #expect(toRoot.base == GitClient.emptyTree && toRoot.target == "c2c2c2c2c2")

    // 不连续：中间没选的也算进 diff，记下有几个，详情里提示
    let gapped = try #require(GitCommitRange.selection(["c4c4c4c4c4", "c1c1c1c1c1"], in: commits))
    #expect(gapped.base == GitClient.emptyTree && gapped.target == "c4c4c4c4c4")
    #expect(gapped.commitCount == 2 && gapped.skippedCount == 2)
    #expect(gapped.note?.contains("中间没选的 2 个提交") == true)

    // 少于两个、或选中的已经不在列表里：不是区间（单选照旧看那次提交）
    #expect(GitCommitRange.selection(["c3c3c3c3c3"], in: commits) == nil)
    #expect(GitCommitRange.selection([], in: commits) == nil)
    #expect(GitCommitRange.selection(["c3c3c3c3c3", "gone"], in: commits) == nil)
}

@Test func rangeTextsDescribeWhatIsCompared() throws {
    let range = try #require(GitCommitRange.selection(["c4c4c4c4c4", "c3c3c3c3c3"], in: commits))
    #expect(range.badge == "c3c3c3c…c4c4c4c")
    #expect(range.summary == "2 个提交（c3c3c3c … c4c4c4c）")
    #expect(range.title(fileCount: nil) == "2 个提交")
    #expect(range.title(fileCount: 5) == "2 个提交 · 5 个文件")
    #expect(range.branch == nil)

    let branch = GitCommitRange.branch("origin/master", mergeBase: "b0", head: "h1", commitCount: 3)
    #expect(branch.base == "b0" && branch.target == "h1" && branch.id == "b0..h1")
    #expect(branch.branch == "origin/master")
    #expect(branch.title(fileCount: 12) == "与 origin/master 比较 · 3 个提交 · 12 个文件")
    #expect(branch.title(fileCount: nil) == "与 origin/master 比较 · 3 个提交")
    #expect(branch.badge == "对比 origin/master")
    #expect(branch.summary == "与 origin/master 比较")
    #expect(branch.note == nil)
    // 当前分支没有比它多的提交（它在前面或就是同一个）：不是出错，说一句
    let empty = GitCommitRange.branch("main", mergeBase: "h1", head: "h1", commitCount: 0)
    #expect(empty.note == "当前分支没有比 main 多的提交。")
}

@Test func compareRangeResolvesMergeBaseAndHead() async throws {
    let runner = FakeCommandRunner { arguments, _ in
        switch arguments.first {
        case "rev-parse": return shellOutput("headhash\n")
        case "merge-base": return shellOutput("basehash\n")
        case "rev-list": return shellOutput("4\n")
        default: return shellOutput("")
        }
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let repo = URL(fileURLWithPath: "/repo")
    let range = try await git.compareRange(withBranch: "origin/master", repositoryRoot: repo)
    #expect(range == .branch("origin/master", mergeBase: "basehash", head: "headhash", commitCount: 4))
    // HEAD 先解析成 hash，merge-base 与提交数都用这个 hash：之后 HEAD 再动也不影响这一次的结果
    #expect(runner.calls.map(\.arguments) == [
        ["rev-parse", "--verify", "-q", "HEAD"],
        ["rev-parse", "--verify", "-q", "HEAD^{commit}"],
        ["merge-base", "origin/master", "headhash"],
        ["rev-list", "--count", "basehash..headhash", "--"],
    ])

    // 列表、文件、统计、单个文件的 diff 都用同一对 base / target
    _ = try await git.log(repositoryRoot: repo, limit: 100, range: range)
    _ = try await git.changedFiles(base: range.base, target: range.target, repositoryRoot: repo)
    _ = try await git.diffStatistics(base: range.base, target: range.target, repositoryRoot: repo)
    _ = try await git.diff(change: GitChange(path: "b.txt", originalPath: "a.txt", kind: .renamed), base: range.base, target: range.target, repositoryRoot: repo)
    let calls = runner.calls.suffix(4).map(\.arguments)
    #expect(calls[0] == ["log", "--date-order", "-z", "--format=" + GitLogParser.format, "-n", "100", "basehash..headhash", "--"])
    #expect(calls[1] == ["diff", "--name-status", "-z", "--find-renames", "basehash", "headhash"])
    #expect(calls[2] == ["diff", "--numstat", "-z", "--no-ext-diff", "--find-renames", "basehash", "headhash", "--"])
    #expect(calls[3] == ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", "basehash", "headhash", "--", "b.txt", "a.txt"])
}

@Test func compareRangeReportsUnrelatedHistories() async {
    // 没有共同祖先时 merge-base 退出码 1、什么都不输出：给一句人话，而不是拿空串当 base 算出一个空区间
    let runner = FakeCommandRunner { arguments, _ in
        arguments.first == "merge-base" ? shellOutput("", status: 1) : shellOutput("headhash\n")
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    await #expect(throws: GitCompareError.noCommonAncestor("other")) {
        _ = try await git.compareRange(withBranch: "other", repositoryRoot: URL(fileURLWithPath: "/repo"))
    }
    #expect(GitCompareError.noCommonAncestor("other").errorDescription == "other 与当前分支没有共同的祖先提交，无法比较")

    // 还没有提交的仓库：rev-parse 失败、不写 stderr，也给一句人话，不往下跑 merge-base
    let unborn = FakeCommandRunner { _, _ in shellOutput("", status: 1) }
    let unbornGit = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: unborn)
    await #expect(throws: GitCompareError.noHead) {
        _ = try await unbornGit.compareRange(withBranch: "origin/main", repositoryRoot: URL(fileURLWithPath: "/repo"))
    }
    #expect(unborn.calls.map { $0.arguments.first } == ["rev-parse"])
}
