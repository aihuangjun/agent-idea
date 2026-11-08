import Core
import Foundation
import Testing
import TestSupport

@Test func diffFileNavigationStopsAtBoundariesAndPreservesListOrder() {
    let paths = ["src/z.swift", "src/a.swift", "root.txt"]
    #expect(DiffFileNavigation.adjacentPath(in: paths, current: paths[0], direction: .next) == paths[1])
    #expect(DiffFileNavigation.adjacentPath(in: paths, current: paths[1], direction: .previous) == paths[0])
    #expect(DiffFileNavigation.adjacentPath(in: paths, current: paths[0], direction: .previous) == nil)
    #expect(DiffFileNavigation.adjacentPath(in: paths, current: paths[2], direction: .next) == nil)
    #expect(DiffFileNavigation.adjacentPath(in: paths, current: "missing", direction: .next) == nil)
    #expect(DiffFileNavigation.adjacentPath(in: [], current: "", direction: .next) == nil)
    #expect(DiffNavigationDirection.next.entryEdge == .first)
    #expect(DiffNavigationDirection.previous.entryEdge == .last)
}

@Test func numstatParsesRenamesBinaryAndUnusualPathsWithoutSplittingLines() {
    let stats = GitNumstatParser.parse(Data("12\t3\tsrc/中文\tfile\n.swift\0-\t-\timage.png\00\t0\t\0old name.txt\0new\tname.txt\0bad\t-2\tbroken\0".utf8))
    #expect(stats["src/中文\tfile\n.swift"] == DiffLineCounts(added: 12, removed: 3))
    #expect(stats["image.png"] == .binary)
    #expect(stats["new\tname.txt"] == DiffLineCounts(added: 0, removed: 0))
    #expect(stats["old name.txt"] == nil)
    #expect(stats.count == 3)
    #expect(GitNumstatParser.parse(Data("1\t2\t\0old\0".utf8)).isEmpty)
}

@Test func addedFileStatisticsHandleEmptyFinalNewlineBinaryAndSymbolicLinks() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("new.txt")
        for (text, lines) in [("", 0), ("a", 1), ("a\n", 1), ("a\r\nb\r\n", 2), ("\n\nlast", 3)] {
            try Data(text.utf8).write(to: file)
            #expect(try DiffLineCounts.addedFile(at: file) == DiffLineCounts(added: lines, removed: 0))
        }
        try Data([1, 0, 2]).write(to: file)
        #expect(try DiffLineCounts.addedFile(at: file) == .binary)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
        #expect(try DiffLineCounts.addedFile(at: link) == DiffLineCounts(added: 1, removed: 0))
        #expect(try DiffLineCounts.addedFile(at: directory) == nil)
    }
}

@Test func gitStatisticsUseHeadAndCommitParentAndCountUntrackedFiles() async throws {
    try await withTemporaryDirectory { directory in
        try "new\nline".write(to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let runner = FakeCommandRunner { arguments, _ in
            if arguments.first == "rev-parse" { return shellOutput("head") }
            return shellOutput("3\t2\ta.txt\0")
        }
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        let stats = try await git.diffStatistics(changes: [GitChange(path: "a.txt", kind: .modified), GitChange(path: "new.txt", kind: .untracked)], repositoryRoot: directory)
        #expect(stats["a.txt"] == DiffLineCounts(added: 3, removed: 2))
        #expect(stats["new.txt"] == DiffLineCounts(added: 2, removed: 0))
        #expect(runner.calls(startingWith: "diff").count == 1)
        #expect(runner.calls(startingWith: "diff")[0].suffix(2) == ["HEAD", "--"])
        let commit = GitCommit(hash: "new", shortHash: "new", parents: ["parent"], authorName: "test", authorEmail: "", authorDate: Date(), subject: "", body: "")
        _ = try await git.diffStatistics(in: commit, repositoryRoot: directory)
        #expect(runner.calls(startingWith: "diff").last?.suffix(3) == ["parent", "new", "--"])
    }
}
