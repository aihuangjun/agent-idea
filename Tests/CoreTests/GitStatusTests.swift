import Core
import Foundation
import Testing

private func porcelain(_ records: [String]) -> String {
    records.joined(separator: "\0") + "\0"
}

@Test func parsesBranchHeaders() {
    let snapshot = GitStatusParser.parse(porcelain([
        "# branch.oid 1234567890abcdef",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -1",
    ]))
    #expect(snapshot.branch.name == "main")
    #expect(snapshot.branch.upstream == "origin/main")
    #expect(snapshot.branch.ahead == 2)
    #expect(snapshot.branch.behind == 1)
    #expect(!snapshot.branch.isDetached)
    #expect(!snapshot.branch.isUnborn)
}

@Test func detachedAndUnbornBranches() {
    let detached = GitStatusParser.parse(porcelain(["# branch.oid abcdef1234567", "# branch.head (detached)"]))
    #expect(detached.branch.isDetached)
    #expect(detached.branch.name == "abcdef1")
    let unborn = GitStatusParser.parse(porcelain(["# branch.oid (initial)", "# branch.head main"]))
    #expect(unborn.branch.isUnborn)
}

@Test func parsesOrdinaryUntrackedIgnoredAndRenamed() {
    let snapshot = GitStatusParser.parse(porcelain([
        "# branch.head main",
        "1 .M N... 100644 100644 100644 abc def Sources/App.swift",
        "1 A. N... 000000 100644 100644 000 def Sources/New file.swift",
        "1 .D N... 100644 100644 000000 abc abc gone.txt",
        "2 R. N... 100644 100644 100644 abc abc R100 new/name.swift",
        "old/name.swift",
        "u UU N... 100644 100644 100644 100644 a b c conflict.swift",
        "? notes.md",
        "! .build/",
        "! secret.env",
    ]))
    let byPath = Dictionary(uniqueKeysWithValues: snapshot.changes.map { ($0.path, $0) })
    #expect(byPath["Sources/App.swift"]?.kind == .modified)
    #expect(byPath["Sources/App.swift"]?.isStaged == false)
    #expect(byPath["Sources/App.swift"]?.isUnstaged == true)
    #expect(byPath["Sources/New file.swift"]?.kind == .added)
    #expect(byPath["Sources/New file.swift"]?.isStaged == true)
    #expect(byPath["gone.txt"]?.kind == .deleted)
    #expect(byPath["new/name.swift"]?.kind == .renamed)
    #expect(byPath["new/name.swift"]?.originalPath == "old/name.swift")
    #expect(byPath["conflict.swift"]?.kind == .conflicted)
    #expect(byPath["notes.md"]?.kind == .untracked)
    #expect(snapshot.ignored == [".build/", "secret.env"])
    #expect(snapshot.changes.count == 6)
}

@Test func statusIndexAggregatesDirectoriesAndIgnores() {
    let snapshot = GitSnapshot(
        branch: GitBranch(name: "main"),
        changes: [
            GitChange(path: "Sources/Core/A.swift", kind: .modified),
            GitChange(path: "Sources/Core/B.swift", kind: .untracked),
            GitChange(path: "Sources/UI/C.swift", kind: .deleted),
        ],
        ignored: [".build/", "Sources/Core/junk.o"]
    )
    let index = GitStatusIndex(snapshot: snapshot)
    #expect(index.status(of: "Sources/Core/A.swift", isDirectory: false) == .change(.modified))
    #expect(index.status(of: "Sources/Core/B.swift", isDirectory: false) == .change(.untracked))
    // 目录取优先级最高的：删除 > 修改 > 未跟踪
    #expect(index.status(of: "Sources", isDirectory: true) == .change(.deleted))
    #expect(index.status(of: "Sources/Core", isDirectory: true) == .change(.modified))
    #expect(index.status(of: "Sources/UI", isDirectory: true) == .change(.deleted))
    #expect(index.status(of: "Tests", isDirectory: true) == nil)
    // 忽略：目录本身、目录里的任何东西、单独匹配的文件
    #expect(index.status(of: ".build", isDirectory: true) == .ignored)
    #expect(index.status(of: ".build/debug/x.o", isDirectory: false) == .ignored)
    #expect(index.status(of: ".build/debug", isDirectory: true) == .ignored)
    #expect(index.status(of: "Sources/Core/junk.o", isDirectory: false) == .ignored)
    #expect(index.changedFileCount == 3)
}

@Test func changeGroupsSplitTrackedAndUntracked() {
    let groups = ChangeGroups(changes: [
        GitChange(path: "b.txt", kind: .untracked),
        GitChange(path: "z.swift", kind: .modified),
        GitChange(path: "a.swift", kind: .added),
    ])
    #expect(groups.tracked.map(\.path) == ["a.swift", "z.swift"])
    #expect(groups.untracked.map(\.path) == ["b.txt"])
    #expect(groups.total == 3)
}

@Test func changeHelpers() {
    let change = GitChange(path: "Sources/Core/A.swift", kind: .modified)
    #expect(change.fileName == "A.swift")
    #expect(change.directory == "Sources/Core")
    #expect(GitChange(path: "top.txt", kind: .added).directory == "")
}

@Test func watcherRelevanceFiltersGitInternals() {
    #expect(DirectoryWatcher.isRelevant("/p/Sources/A.swift"))
    #expect(DirectoryWatcher.isRelevant("/p/.git/index"))
    #expect(DirectoryWatcher.isRelevant("/p/.git/HEAD"))
    #expect(DirectoryWatcher.isRelevant("/p/.git/refs/heads/main"))
    #expect(!DirectoryWatcher.isRelevant("/p/.git/index.lock"))
    #expect(!DirectoryWatcher.isRelevant("/p/.git/objects/ab/cdef"))
    #expect(!DirectoryWatcher.isRelevant("/p/.git/FETCH_HEAD"))
}
