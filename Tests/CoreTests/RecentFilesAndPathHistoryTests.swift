import Core
import Foundation
import Testing

// MARK: - 最近的文件

private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func recentFilesRecordMovesToFrontDedupesAndCaps() {
    var recent = RecentFiles(capacity: 3)
    recent.record("a.swift", at: date(1))
    recent.record("b.swift", at: date(2))
    recent.record("a.swift", at: date(3))
    // 再开一次 a：挪到最前面，不重复
    #expect(recent.entries.map(\.path) == ["a.swift", "b.swift"])
    #expect(recent.entries.first?.openedAt == date(3))
    recent.record("c.swift", at: date(4))
    recent.record("d.swift", at: date(5))
    // 超过上限丢最老的
    #expect(recent.entries.map(\.path) == ["d.swift", "c.swift", "a.swift"])
    recent.record("", at: date(6))
    #expect(recent.entries.count == 3)
    #expect(RecentFiles().capacity == 50)
}

@Test func recentFilesInitNormalizesStoredEntries() {
    // 存档顺序乱、有重复、超上限：按时间新到旧排，同一路径留最新那条
    let stored = [RecentFiles.Entry(path: "old", openedAt: date(1)), RecentFiles.Entry(path: "new", openedAt: date(9)),
                  RecentFiles.Entry(path: "old", openedAt: date(5)), RecentFiles.Entry(path: "mid", openedAt: date(4)),
                  RecentFiles.Entry(path: "", openedAt: date(10))]
    let recent = RecentFiles(entries: stored, capacity: 2)
    #expect(recent.entries.map(\.path) == ["new", "old"])
    #expect(recent.entries.last?.openedAt == date(5))
}

@Test func recentFilesExcludeCurrentKeepClosedAndPrune() {
    var recent = RecentFiles()
    for (index, path) in ["a", "b", "c"].enumerated() { recent.record(path, at: date(TimeInterval(index))) }
    // 当前是 c：不列它，第一项就是上一个文件
    #expect(recent.candidates(excluding: "c").map(\.path) == ["b", "a"])
    #expect(recent.candidates(excluding: nil).map(\.path) == ["c", "b", "a"])
    let removed = recent.removeAll { $0.path == "b" }
    let removedNothing = recent.removeAll { $0.path == "zzz" }
    #expect(removed && !removedNothing)
    #expect(recent.entries.map(\.path) == ["c", "a"])
}

@Test func recentFilesRenameFollowsFilesAndDirectories() {
    var recent = RecentFiles()
    recent.record("src/a.swift", at: date(1))
    recent.record("src/sub/b.swift", at: date(2))
    recent.record("srcx/c.swift", at: date(3))
    recent.record("lib/a.swift", at: date(4))
    // 目录改名：下面的都跟着换，前缀相同的兄弟目录 srcx 不动
    let renamedDirectory = recent.rename(from: "src", to: "core")
    #expect(renamedDirectory)
    #expect(recent.entries.map(\.path) == ["lib/a.swift", "srcx/c.swift", "core/sub/b.swift", "core/a.swift"])
    // 文件改名到一个已有条目的名字：只留排前（最近）的那一条
    let renamedFile = recent.rename(from: "core/a.swift", to: "lib/a.swift")
    #expect(renamedFile)
    #expect(recent.entries.map(\.path) == ["lib/a.swift", "srcx/c.swift", "core/sub/b.swift"])
    let renamedNothing = recent.rename(from: "nope", to: "x")
    #expect(!renamedNothing)
}

@Test func recentFilesFilterUsesFileSearchScoringAndKeepsRecencyOnTies() {
    let entries = ["Sources/AppModel.swift", "README.md", "Tests/AppModelTests.swift", "Sources/Other/AppModel.swift"]
        .enumerated().map { RecentFiles.Entry(path: $0.element, openedAt: date(TimeInterval(10 - $0.offset))) }
    // 空查询：原样（最近的在前）
    #expect(RecentFiles.filter(entries, query: " ").map(\.entry.path) == entries.map(\.path))
    // 前缀命中排在子序列前面（AppModelTests.swift 只是子序列）；同分（两个 AppModel.swift）保持最近打开的顺序
    let found = RecentFiles.filter(entries, query: "appmodel.swift")
    #expect(found.map(\.entry.path) == ["Sources/AppModel.swift", "Sources/Other/AppModel.swift", "Tests/AppModelTests.swift"])
    #expect(found.first?.matchedNameIndices == Array(0..<14))
    // 都是前缀命中时纯按最近打开排
    #expect(RecentFiles.filter(entries, query: "appmodel").map(\.entry.path) == ["Sources/AppModel.swift", "Tests/AppModelTests.swift", "Sources/Other/AppModel.swift"])
    // 子序列：amdl → AppModel
    #expect(RecentFiles.filter(entries, query: "amdl").map(\.entry.path).first == "Sources/AppModel.swift")
    // 带 / 按路径
    #expect(RecentFiles.filter(entries, query: "other/").map(\.entry.path) == ["Sources/Other/AppModel.swift"])
    #expect(RecentFiles.filter(entries, query: "zzz").isEmpty)
}

// MARK: - 文件历史

@Test func pathFilterBuildsFollowArgumentsForFilesAndSkipForDirectories() {
    let file = GitPathFilter(path: "Sources/Foo.swift", isDirectory: false)
    #expect(file.follows)
    // --follow 下 --skip 是坏的：拉 skip + limit 个，自己丢掉前面的；路径在 -- 之后
    #expect(file.logArguments(limit: 100, skip: 0) == [
        "log", "--date-order", "-z", "--format=%x1e" + GitLogParser.format, "--name-status", "-n", "100", "--follow", "--", "Sources/Foo.swift",
    ])
    #expect(file.logArguments(limit: 100, skip: 100).contains("200"))
    #expect(!file.logArguments(limit: 100, skip: 100).contains("--skip"))

    let directory = GitPathFilter(path: "Sources/", isDirectory: true, displayPath: "Sources")
    #expect(directory.path == "Sources" && !directory.follows)
    #expect(directory.logArguments(limit: 100, skip: 0) == ["log", "--date-order", "-z", "--format=" + GitLogParser.format, "-n", "100", "--", "Sources"])
    #expect(directory.logArguments(limit: 100, skip: 100) == ["log", "--date-order", "-z", "--format=" + GitLogParser.format, "-n", "100", "--skip", "100", "--", "Sources"])
    #expect(directory.title == "Sources/ 的历史")
    #expect(GitPathFilter(path: "a/b.swift", isDirectory: false, displayPath: "b.swift").title == "b.swift 的历史")
}

@Test func pathFilterMatchesAndPrioritizesTheFileItIsFollowing() {
    let file = GitPathFilter(path: "new.swift", isDirectory: false)
    let changes = [GitChange(path: "a.swift", kind: .modified), GitChange(path: "new.swift", originalPath: "old.swift", kind: .renamed),
                   GitChange(path: "z.swift", kind: .added)]
    #expect(file.prioritized(changes).map(\.path) == ["new.swift", "a.swift", "z.swift"])
    // 改名之前的提交里它叫 old.swift
    let older = [GitChange(path: "a.swift", kind: .modified), GitChange(path: "old.swift", kind: .modified)]
    #expect(file.prioritized(older, pathAtCommit: "old.swift").map(\.path) == ["old.swift", "a.swift"])
    #expect(!file.matches(older[1]))
    // 重命名那一条按旧名也认
    #expect(GitPathFilter(path: "old.swift", isDirectory: false).matches(changes[1]))

    let directory = GitPathFilter(path: "src", isDirectory: true)
    let mixed = [GitChange(path: "README.md", kind: .modified), GitChange(path: "src/a.swift", kind: .modified),
                 GitChange(path: "srcx/b.swift", kind: .modified), GitChange(path: "lib/c.swift", originalPath: "src/c.swift", kind: .renamed)]
    #expect(directory.prioritized(mixed).map(\.path) == ["src/a.swift", "lib/c.swift", "README.md", "srcx/b.swift"])
    // 全是或全不是：原样
    #expect(directory.prioritized([mixed[0]]).map(\.path) == ["README.md"])
}

private let us = "\u{1f}"
private func followRecord(_ hash: String, subject: String, status: String) -> String {
    "\u{1e}" + [hash, String(hash.prefix(7)), "p", "Alice", "a@x.io", "1725000000", "1725000000", subject, "正文\n第二行"].joined(separator: us) + "\0" + status
}

@Test func pathHistoryParserReadsNameStatusAndSkips() {
    // 新到旧：改内容、合并（--name-status 对合并提交不输出）、改名、新建
    let text = followRecord("c4c4c4c4c4", subject: "改", status: "\nM\0new.swift\0")
        + followRecord("c3c3c3c3c3", subject: "合并", status: "")
        + followRecord("c2c2c2c2c2", subject: "改名", status: "\nR087\0old.swift\0new.swift\0")
        + followRecord("c1c1c1c1c1", subject: "新建", status: "\nA\0old.swift\0")
    let page = GitPathHistoryParser.parse(text)
    #expect(page.commits.map(\.subject) == ["改", "合并", "改名", "新建"])
    #expect(page.commits.first?.body == "正文\n第二行")
    #expect(page.paths == ["c4c4c4c4c4": "new.swift", "c2c2c2c2c2": "new.swift", "c1c1c1c1c1": "old.swift"])

    let skipped = GitPathHistoryParser.parse(text, skip: 2)
    #expect(skipped.commits.map(\.subject) == ["改名", "新建"])
    #expect(skipped.paths == ["c2c2c2c2c2": "new.swift", "c1c1c1c1c1": "old.swift"])
    #expect(GitPathHistoryParser.parse("").commits.isEmpty)
}

// MARK: - Amend

@Test func commitArgumentsForAmend() {
    #expect(GitClient.commitArguments(paths: ["a", "b"], message: "m", amend: false) == ["commit", "--quiet", "--only", "-m", "m", "--", "a", "b"])
    #expect(GitClient.commitArguments(paths: ["a"], message: "m", amend: true) == ["commit", "--quiet", "--amend", "--only", "-m", "m", "--", "a"])
    // 没勾文件：只改信息，不带 --
    #expect(GitClient.commitArguments(paths: [], message: "m", amend: true) == ["commit", "--quiet", "--amend", "--only", "-m", "m"])
}
