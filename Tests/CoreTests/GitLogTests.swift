import Core
import Foundation
import Testing
import TestSupport

private let us = "\u{1f}"

@Test func logParserSplitsRecordsAndFields() {
    let text = [
        ["aaaa1111", "aaaa111", "bbbb2222 cccc3333", "张三", "zs@example.com", "1725000000", "合并 feature", "正文第一行\n\n第二段\n"].joined(separator: us),
        ["bbbb2222", "bbbb222", "", "Alice", "a@x.io", "1724000000", "initial: 带 \"引号\" 与 / 斜杠", ""].joined(separator: us),
    ].joined(separator: "\0") + "\0"
    let commits = GitLogParser.parse(text)
    #expect(commits.count == 2)
    #expect(commits[0].hash == "aaaa1111" && commits[0].shortHash == "aaaa111")
    #expect(commits[0].parents == ["bbbb2222", "cccc3333"] && commits[0].isMerge)
    #expect(commits[0].authorName == "张三" && commits[0].authorEmail == "zs@example.com")
    #expect(commits[0].date == Date(timeIntervalSince1970: 1_725_000_000))
    #expect(commits[0].subject == "合并 feature")
    #expect(commits[0].body == "正文第一行\n\n第二段")
    #expect(commits[0].diffBase == "bbbb2222")
    // 根提交：没有父提交，对比空树
    #expect(commits[1].parents.isEmpty && !commits[1].isMerge)
    #expect(commits[1].diffBase == GitClient.emptyTree)
    #expect(commits[1].body.isEmpty)
    #expect(GitLogParser.parse("").isEmpty)
}

@Test func nameStatusParserHandlesRenamesAndSorts() {
    let text = "M\0src/b.swift\0A\0zz/new.txt\0R087\0old/name.md\0docs/name.md\0D\0gone.py\0T\0link\0C075\0a.txt\0copy.txt\0"
    let changes = GitNameStatusParser.parse(text)
    #expect(changes.map(\.path) == ["copy.txt", "docs/name.md", "gone.py", "link", "src/b.swift", "zz/new.txt"])
    #expect(changes.first { $0.path == "docs/name.md" }?.originalPath == "old/name.md")
    #expect(changes.first { $0.path == "docs/name.md" }?.kind == .renamed)
    #expect(changes.first { $0.path == "copy.txt" }?.kind == .added)
    #expect(changes.first { $0.path == "copy.txt" }?.originalPath == nil)
    #expect(changes.first { $0.path == "gone.py" }?.kind == .deleted)
    #expect(changes.first { $0.path == "link" }?.kind == .modified)
    #expect(changes.first { $0.path == "zz/new.txt" }?.kind == .added)
    #expect(GitNameStatusParser.parse("").isEmpty)
}

@Test func statusParserRecordsHeadOID() {
    let snapshot = GitStatusParser.parse("# branch.oid deadbeef\u{0}# branch.head main\u{0}")
    #expect(snapshot.branch.headOID == "deadbeef")
    let unborn = GitStatusParser.parse("# branch.oid (initial)\u{0}# branch.head main\u{0}")
    #expect(unborn.branch.isUnborn && unborn.branch.headOID.isEmpty)
}

@Test func logAndCommitDiffArguments() async throws {
    let repo = URL(fileURLWithPath: "/repo")
    let record = ["abc", "abc", "", "A", "a@b", "1", "s", ""].joined(separator: us) + "\0"
    let runner = FakeCommandRunner(responses: [shellOutput("head"), shellOutput(record), shellOutput("M\0a.swift\0"), shellOutput("diff")])
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let commits = try await git.log(repositoryRoot: repo, limit: 50)
    #expect(commits.map(\.hash) == ["abc"])
    #expect(runner.calls[0].arguments == ["rev-parse", "--verify", "-q", "HEAD"])
    #expect(runner.calls[1].arguments == ["log", "-z", "--format=" + GitLogParser.format, "-n", "50"])
    let files = try await git.changedFiles(in: commits[0], repositoryRoot: repo)
    #expect(files.map(\.path) == ["a.swift"])
    #expect(runner.calls[2].arguments == ["diff", "--name-status", "-z", "--find-renames", GitClient.emptyTree, "abc"])
    _ = try await git.diff(change: GitChange(path: "b.md", originalPath: "a.md", kind: .renamed), in: commits[0], repositoryRoot: repo)
    #expect(runner.calls[3].arguments == ["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", GitClient.emptyTree, "abc", "--", "b.md", "a.md"])

    // 翻页：第一页已经证明有 HEAD，不再 rev-parse
    let paging = FakeCommandRunner(responses: [shellOutput(record)])
    _ = try await GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: paging).log(repositoryRoot: repo, limit: 50, skip: 100)
    #expect(paging.calls.map(\.arguments) == [["log", "-z", "--format=" + GitLogParser.format, "-n", "50", "--skip", "100"]])

    // 没有提交的仓库：不跑 log，直接空
    let unborn = FakeCommandRunner(responses: [shellOutput("", status: 1)])
    let empty = try await GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: unborn).log(repositoryRoot: repo, limit: 10)
    #expect(empty.isEmpty && unborn.calls.count == 1)
}
