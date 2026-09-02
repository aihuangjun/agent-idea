import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private let us = "\u{1f}"
private func logRecord(_ hash: String, parents: String, subject: String) -> String {
    [hash, String(hash.prefix(7)), parents, "Alice", "a@x.io", "1725000000", subject, ""].joined(separator: us) + "\0"
}

@Test @MainActor func historyLoadsPagesSelectsAndOpensCommitDiff() async throws {
    try await withTemporaryDirectory { directory in
        let head = Locked("c2c2c2c2c2c2c2c2")
        let untracked = Locked<[String]>([])
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path + "\n")
            case "rev-parse": return shellOutput(head.value)
            case "status": return shellOutput("# branch.oid \(head.value)\u{0}# branch.head main\u{0}" + untracked.value.map { "? \($0)\u{0}" }.joined())
            case "log":
                let skip = arguments.firstIndex(of: "--skip").map { Int(arguments[$0 + 1]) ?? 0 } ?? 0
                if skip == 0 {
                    // 恰好一整页：说明还有更多
                    let page = (0..<HistoryController.pageSize).map { logRecord(String(format: "%016x", 0x1000 + $0), parents: $0 == HistoryController.pageSize - 1 ? "" : String(format: "%016x", 0x1001 + $0), subject: "提交 \($0)") }
                    return shellOutput(page.joined())
                }
                return shellOutput(logRecord("0000000000000abc", parents: "", subject: "root"))
            case "diff" where arguments.contains("--name-status"):
                return shellOutput("M\0src/a.swift\0A\0b.md\0")
            case "diff":
                return shellOutput("diff --git a/src/a.swift b/src/a.swift\n--- a/src/a.swift\n+++ b/src/a.swift\n@@ -1 +1 @@\n-old\n+new\n")
            default: return shellOutput("")
            }
        }
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        let session = ProjectSession(root: directory, git: git, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        await waitUntil { session.history != nil && session.gitSnapshot.branch.name == "main" }
        let history = try #require(session.history)
        // 没打开过历史：不主动拉
        #expect(runner.calls(startingWith: "log").isEmpty)

        history.loadIfNeeded()
        await waitUntil { !history.commits.isEmpty && !history.isLoading }
        #expect(history.commits.count == HistoryController.pageSize)
        #expect(history.hasMore)
        #expect(runner.calls(startingWith: "log").last == ["log", "-z", "--format=" + GitLogParser.format, "-n", "100"])

        history.loadMore()
        await waitUntil { history.commits.count > HistoryController.pageSize }
        #expect(history.commits.last?.subject == "root")
        #expect(history.hasMore == false)
        #expect(runner.calls(startingWith: "log").last?.suffix(2) == ["--skip", "100"])

        // 选中 → 拉文件列表
        let first = history.commits[0]
        history.select(first)
        await waitUntil { history.filesByCommit[first.id] != nil }
        #expect(history.filesByCommit[first.id]?.map(\.path) == ["b.md", "src/a.swift"])
        #expect(runner.calls(startingWith: "diff").last == ["diff", "--name-status", "-z", "--find-renames", first.parents[0], first.hash])
        history.moveSelection(by: 1)
        #expect(history.selectedCommit?.subject == "提交 1")

        // 打开提交里的文件 diff：标签 id 带 hash，内容是 diff；工作区 git 刷新不会把它关掉
        let change = try #require(history.filesByCommit[first.id]?.first)
        session.openCommitDiff(change, in: first)
        let tab = try #require(session.activeTab)
        #expect(tab.id == "commit:\(first.hash):b.md")
        #expect(tab.isDiff && tab.change == nil && tab.commitDiff?.commit == first)
        #expect(tab.isPreview)
        await waitUntil { session.activeContent != .loading && session.activeContent != nil }
        guard case .diff(let diff, _) = session.activeContent else { Issue.record("应是 diff"); return }
        #expect(diff.addedCount == 1 && diff.removedCount == 1)
        // 「提交 1」的文件列表还在后台拉，和这次 diff 谁先谁后不定，只看有没有
        #expect(runner.calls(startingWith: "diff").contains(["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", first.parents[0], first.hash, "--", "b.md"]))
        // 每次刷新让 status 多报一个未跟踪文件，好确认「这一轮刷新的结果已经落地」再断言
        untracked.value = ["one.txt"]
        session.refreshGit()
        await waitUntil { session.gitSnapshot.changes.count == 1 }
        #expect(session.tabs.count == 1)

        // HEAD 没变 → 不重拉历史；变了（有新提交）→ 重拉一次
        let logCalls = runner.calls(startingWith: "log").count
        untracked.value = ["one.txt", "two.txt"]
        session.refreshGit()
        await waitUntil { session.gitSnapshot.changes.count == 2 }
        #expect(runner.calls(startingWith: "log").count == logCalls)
        head.value = "d3d3d3d3d3d3d3d3"
        session.refreshGit()
        await waitUntil { runner.calls(startingWith: "log").count > logCalls }
        #expect(runner.calls(startingWith: "log").count == logCalls + 1)
    }
}

@Test @MainActor func fileSearchIndexesLazilyAndSkipsIgnored() async throws {
    try await withTemporaryDirectory { directory in
        let fm = FileManager.default
        for path in ["Sources/App/AppModel.swift", "Sources/Core/Model.swift", ".build/junk.swift", "docs/guide.md"] {
            let url = directory.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path + "\n")
            case "status": return shellOutput("# branch.oid abc\u{0}# branch.head main\u{0}! .build/\u{0}")
            default: return shellOutput("")
            }
        }
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner),
                                     renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        await waitUntil { session.gitIndex.isIgnored(".build", isDirectory: true) }
        let search = session.search
        #expect(search.indexedCount == 0)

        search.isActive = true
        await waitUntil { !search.isIndexing && search.indexedCount > 0 }
        #expect(search.indexedCount == 3)

        search.query = "model"
        await waitUntil { !search.results.isEmpty }
        #expect(search.results.map(\.entry.path) == ["Sources/Core/Model.swift", "Sources/App/AppModel.swift"])
        #expect(search.selectedIndex == 0)
        search.moveSelection(by: 1)
        #expect(search.selectedResult?.entry.name == "AppModel.swift")
        #expect(search.url(for: search.selectedResult!).path == directory.appendingPathComponent("Sources/App/AppModel.swift").path)
        search.moveSelection(by: 5)
        #expect(search.selectedIndex == 1)

        // 被忽略的文件搜不到；旧结果在新结果到达时被替换
        search.query = "junk"
        await waitUntil { search.results.isEmpty }
        #expect(search.results.isEmpty)

        // 关掉搜索会清空查询
        search.isActive = false
        #expect(search.query.isEmpty && search.results.isEmpty)
        search.isActive = true

        // 目录变化增量更新：新文件、新目录（连里面的文件）、删掉的文件
        let newFile = directory.appendingPathComponent("docs/new-model.md")
        try "y".write(to: newFile, atomically: true, encoding: .utf8)
        let newDirectory = directory.appendingPathComponent("Sources/Extra")
        try fm.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        try "z".write(to: newDirectory.appendingPathComponent("Thing.swift"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: directory.appendingPathComponent("docs/guide.md"))
        search.applyChanges([newFile.path, newDirectory.path, directory.appendingPathComponent("docs/guide.md").path])
        #expect(search.indexedCount == 4)
        search.query = "new-model"
        await waitUntil { !search.results.isEmpty }
        #expect(search.results.first?.entry.path == "docs/new-model.md")
        search.query = "thing"
        await waitUntil { search.results.first?.entry.path == "Sources/Extra/Thing.swift" }
        search.query = "guide"
        await waitUntil { search.results.isEmpty }

        // 忽略规则变了：整个索引作废重建（.build 不再被忽略 → junk.swift 进来）
        search.markStale()
        await waitUntil { search.indexedCount == 4 && !search.isIndexing }
        search.isExcluded = { _, _ in false }
        search.markStale()
        await waitUntil { search.indexedCount == 5 }
    }
}
