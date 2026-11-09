import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@MainActor
private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private let us = "\u{1f}"
private func logRecord(_ hash: String, parents: String, subject: String) -> String {
    [hash, String(hash.prefix(7)), parents, "Alice", "a@x.io", "1725000000", "1725000000", subject, ""].joined(separator: us) + "\0"
}

private let c3 = "c3c3c3c3c3c3c3c3", c2 = "c2c2c2c2c2c2c2c2", c1 = "c1c1c1c1c1c1c1c1"
private let mergeBaseHash = "bbbbbbbbbbbbbbbb"

/// 假仓库：HEAD 是 c3 → c2 → c1（根）。普通 log 列三个；带区间的 log（比较模式）只列 c3、c2。
/// `merge-base` 给 `mergeBase` 里的值，`rev-list --count` 给 2。
private func makeRunner(directory: URL, head: Locked<String>, untracked: Locked<[String]>, mergeBase: Locked<String>) -> FakeCommandRunner {
    FakeCommandRunner { arguments, _ in
        switch arguments.first {
        case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path + "\n")
        case "rev-parse": return shellOutput(head.value + "\n")
        case "status": return shellOutput("# branch.oid \(head.value)\u{0}# branch.head main\u{0}" + untracked.value.map { "? \($0)\u{0}" }.joined())
        case "merge-base": return shellOutput(mergeBase.value + "\n")
        case "rev-list": return shellOutput("2\n")
        case "log":
            let all = [logRecord(c3, parents: c2, subject: "三"), logRecord(c2, parents: c1, subject: "二"), logRecord(c1, parents: "", subject: "一")]
            return shellOutput((arguments.contains { $0.contains("..") } ? Array(all.prefix(2)) : all).joined())
        case "diff" where arguments.contains("--name-status"): return shellOutput("M\0a.txt\0A\0b.txt\0")
        case "diff" where arguments.contains("--numstat"): return shellOutput("1\t1\ta.txt\0" + "3\t0\tb.txt\0")
        case "diff": return shellOutput("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n")
        case "show": return shellOutput("", status: 128, stderr: "object unavailable")
        default: return shellOutput("")
        }
    }
}

@Test @MainActor func historyMultiSelectionShowsCombinedFilesAndOpensRangeDiff() async throws {
    try await withTemporaryDirectory { directory in
        let head = Locked(c3), untracked = Locked<[String]>([]), mergeBase = Locked(mergeBaseHash)
        let runner = makeRunner(directory: directory, head: head, untracked: untracked, mergeBase: mergeBase)
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        let session = ProjectSession(root: directory, git: git, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        await waitUntil { session.history != nil && session.gitSnapshot.branch.name == "main" }
        let history = try #require(session.history)
        history.loadIfNeeded()
        await waitUntil { history.commits.count == 3 && !history.isLoading }
        let commits = history.commits

        // 单选照旧：详情是那一次提交
        history.select(commits[0])
        #expect(history.detail == .commit(commits[0]))

        // ⇧点击连选到根：一段区间，base 是空树（根提交没有父提交），target 是最新那个
        history.extendSelection(to: commits[2])
        guard case .range(let range) = history.detail else { Issue.record("应是区间"); return }
        #expect(history.selectedCommitID == nil && history.selectedCommit == nil)
        #expect(range.base == GitClient.emptyTree && range.target == c3 && range.commitCount == 3)
        await waitUntil { history.files[range.id] != nil && history.statistics[range.id] != nil }
        #expect(history.files[range.id]?.map(\.path) == ["a.txt", "b.txt"])
        #expect(history.statistics[range.id]?["b.txt"] == DiffLineCounts(added: 3, removed: 0))
        #expect(runner.calls(startingWith: "diff").contains(["diff", "--name-status", "-z", "--find-renames", GitClient.emptyTree, c3]))

        // ⌘点击去掉中间那个：仍是同一段（两头没变），但记着中间有一个没选
        history.toggleSelection(commits[1])
        guard case .range(let gapped) = history.detail else { Issue.record("应是区间"); return }
        #expect(gapped.id == range.id && gapped.skippedCount == 1 && gapped.commitCount == 2)
        // ⌘点击再去掉一个：剩一个，回到单个提交
        history.toggleSelection(commits[2])
        #expect(history.detail == .commit(commits[0]))

        // 右键「比较从这里到 HEAD」：从 c2 选到最上面；base = c2 的父提交
        history.selectThroughHead(from: commits[1])
        #expect(history.selection.paths == [c3, c2])
        #expect(history.selection.anchor == c2)
        guard case .range(let toHead) = history.detail else { Issue.record("应是区间"); return }
        #expect(toHead.base == c1 && toHead.target == c3)
        await waitUntil { history.files[toHead.id] != nil }

        // 打开区间里的文件：标签 id 带区间，标题能看出是区间；不是工作区变更，git 刷新不会关掉它
        let change = try #require(history.files[toHead.id]?.first)
        session.openHistoryDiff(change, in: .range(toHead))
        let tab = try #require(session.activeTab)
        #expect(tab.id == "range:\(c1)..\(c3):a.txt")
        #expect(tab.isDiff && tab.change == nil && tab.commitDiff == nil && tab.rangeDiff?.range == toHead)
        #expect(tab.historyFilesKey == toHead.id)
        #expect(session.documentID(for: tab) == nil)
        await waitUntil { session.activeContent != .loading && session.activeContent != nil }
        guard case .diff(let diff, _) = session.activeContent else { Issue.record("应是 diff"); return }
        #expect(diff.addedCount == 1 && diff.removedCount == 1)
        #expect(runner.calls(startingWith: "diff").contains(["diff", "--no-color", "--no-ext-diff", "-U3", "--find-renames", c1, c3, "--", "a.txt"]))
        // 跨文件导航用的是区间的文件列表：文件 1/2
        #expect(session.diffReviewProgress.fileIndex == 1 && session.diffReviewProgress.fileCount == 2)

        untracked.value = ["one.txt"]
        session.refreshGit()
        await waitUntil { session.gitSnapshot.changes.count == 1 }
        #expect(session.tabs.map(\.id) == [tab.id])
    }
}

@Test @MainActor func compareWithBranchEntersAndLeavesComparisonMode() async throws {
    try await withTemporaryDirectory { directory in
        let head = Locked(c3), untracked = Locked<[String]>([]), mergeBase = Locked(mergeBaseHash)
        let runner = makeRunner(directory: directory, head: head, untracked: untracked, mergeBase: mergeBase)
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        let session = ProjectSession(root: directory, git: git, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        await waitUntil { session.history != nil && session.gitSnapshot.branch.name == "main" }
        let history = try #require(session.history)
        let requested = Locked<ToolWindow?>(nil)
        session.onRequestToolWindow = { requested.value = $0 }
        session.isBranchPopupShown = true
        // history 随会话一起建好（不是打开工具窗口时才懒建）；此时还从没打开过提交历史、一次 log 都没拉过
        #expect(runner.calls(startingWith: "log").isEmpty)

        // 从分支弹窗进来：关弹窗、切到提交历史；历史还没打开过，它出现时的 loadIfNeeded 不能再拉普通 log 盖掉比较
        session.compareWithCurrentBranch("origin/master")
        #expect(session.isBranchPopupShown == false)
        #expect(requested.value == .history)
        #expect(history.comparedBranch == "origin/master")
        history.loadIfNeeded()
        await waitUntil { history.comparison != nil && history.commits.count == 2 && !history.isLoading }
        let comparison = try #require(history.comparison)
        #expect(comparison == .branch("origin/master", mergeBase: mergeBaseHash, head: c3, commitCount: 2))
        #expect(runner.calls(startingWith: "merge-base") == [["merge-base", "origin/master", c3]])
        let logs = runner.calls(startingWith: "log")
        #expect(logs.count == 1 && logs.last?.suffix(2) == ["\(mergeBaseHash)..\(c3)", "--"])

        // 什么都没选时详情是整段比较；标题写清楚在比什么
        #expect(history.detail == .range(comparison))
        await waitUntil { history.files[comparison.id] != nil }
        #expect(comparison.title(fileCount: history.files[comparison.id]?.count) == "与 origin/master 比较 · 2 个提交 · 2 个文件")
        #expect(runner.calls(startingWith: "diff").contains(["diff", "--name-status", "-z", "--find-renames", mergeBaseHash, c3]))

        // 比较模式里也能单选某个提交看；select(nil)（点标题那一条）回到整段
        history.select(history.commits[1])
        #expect(history.detail == .commit(history.commits[1]))
        history.select(nil)
        #expect(history.detail == .range(comparison))

        // 开着的区间 diff 标签记的是定死的 hash：HEAD 之后再动，标签不变；比较按分支名重算
        let change = try #require(history.files[comparison.id]?.first)
        session.openHistoryDiff(change, in: .range(comparison), pinned: true)
        let tabID = try #require(session.activeTab?.id)
        head.value = "c4c4c4c4c4c4c4c4"
        mergeBase.value = c2
        session.refreshGit()
        await waitUntil { history.comparison?.target == "c4c4c4c4c4c4c4c4" && !history.isLoading }
        #expect(history.comparison?.base == c2)
        #expect(history.comparedBranch == "origin/master")
        #expect(session.tabs.map(\.id) == [tabID])

        // 退出：回到普通历史（不带区间的 log）
        history.exitComparison()
        #expect(history.comparedBranch == nil && history.comparison == nil && history.detail == nil)
        await waitUntil { history.commits.count == 3 && !history.isLoading }
        #expect(runner.calls(startingWith: "log").last?.contains { $0.contains("..") } == false)
    }
}

@Test @MainActor func compareWithUnrelatedBranchShowsAnError() async throws {
    try await withTemporaryDirectory { directory in
        let head = Locked(c3), untracked = Locked<[String]>([]), mergeBase = Locked("")
        let runner = makeRunner(directory: directory, head: head, untracked: untracked, mergeBase: mergeBase)
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
        let session = ProjectSession(root: directory, git: git, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        await waitUntil { session.history != nil && session.gitSnapshot.branch.name == "main" }
        let history = try #require(session.history)
        session.compareWithCurrentBranch("orphan")
        await waitUntil { history.error != nil }
        #expect(history.error == "orphan 与当前分支没有共同的祖先提交，无法比较")
        #expect(history.comparedBranch == "orphan" && history.comparison == nil && history.commits.isEmpty)
        #expect(runner.calls(startingWith: "log").isEmpty)
    }
}
