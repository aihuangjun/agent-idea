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

@MainActor
private func makeSession(_ directory: URL, runner: FakeCommandRunner?, defaults: UserDefaults? = nil) -> ProjectSession {
    let defaults = defaults ?? UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
    return ProjectSession(root: directory, git: runner.map { GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: $0) },
                          renderer: ContentRenderer(), preferences: ReadingPreferences(defaults: defaults), defaults: defaults)
}

// MARK: - 修改上一次提交（Amend）

/// 假仓库：HEAD 是 h1，上一次提交的信息是「上一次」；`branch -r --contains` 的输出由 `remoteBranches` 给。
private func amendRunner(root: String, head: Locked<String>, remoteBranches: Locked<String>, unborn: Bool = false) -> FakeCommandRunner {
    FakeCommandRunner { arguments, _ in
        switch arguments.first {
        case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(root + "\n")
        case "rev-parse" where arguments.contains("--short"): return shellOutput(String(head.value.prefix(7)) + "\n")
        case "rev-parse": return shellOutput(head.value + "\n")
        case "status":
            let oid = unborn ? "(initial)" : head.value
            return shellOutput("# branch.oid \(oid)\u{0}# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +0 -0\u{0}"
                               + "1 .M N... 100644 100644 100644 a b a.txt\u{0}")
        case "log" where arguments.contains("--format=%B"):
            return shellOutput(head.value.hasPrefix("h1") ? "上一次\n\n正文\n\n" : "Agent 的新提交（\(head.value.prefix(2))）\n")
        case "branch": return shellOutput(remoteBranches.value)
        case "commit": head.value = "h2h2h2h2h2"; return shellOutput("")
        default: return shellOutput("")
        }
    }
}

@Test @MainActor func amendPrefillsHeadMessageAndRestoresWhatWasTyped() async throws {
    try await withTemporaryDirectory { directory in
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let head = Locked("h1h1h1h1h1"), remote = Locked("")
        let runner = amendRunner(root: directory.resolvingSymlinksInPath().path, head: head, remoteBranches: remote)
        let session = makeSession(directory, runner: runner)
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)
        #expect(commit.canAmend)

        commit.message = "我自己写的"
        commit.setAmending(true)
        #expect(commit.isAmending)
        // HEAD 的完整信息预填进来，结尾的空行去掉
        await waitUntil { commit.message == "上一次\n\n正文" }
        #expect(commit.message == "上一次\n\n正文")
        #expect(runner.calls(startingWith: "log").contains(["log", "-1", "--format=%B", "HEAD", "--"]))
        // 没推送过：查过了、不警告
        await waitUntil { commit.isAmendTargetPushed != nil }
        #expect(commit.isAmendTargetPushed == false)
        #expect(runner.calls(startingWith: "branch").first == ["branch", "-r", "--contains", "HEAD"])

        // 取消勾选：还原勾之前自己写的
        commit.setAmending(false)
        #expect(!commit.isAmending && commit.message == "我自己写的")
        #expect(commit.isAmendTargetPushed == nil)

        // 勾上之后预填还没到时用户自己改了输入框：不覆盖
        commit.setAmending(true)
        commit.message = "抢先改了"
        await waitUntil { commit.isAmendTargetPushed != nil }
        #expect(commit.message == "抢先改了")
        commit.setAmending(false)
        #expect(commit.message == "我自己写的")
    }
}

@Test @MainActor func amendCommitsOnlySelectedPathsOrJustTheMessage() async throws {
    try await withTemporaryDirectory { directory in
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let head = Locked("h1h1h1h1h1"), remote = Locked("")
        let runner = amendRunner(root: directory.resolvingSymlinksInPath().path, head: head, remoteBranches: remote)
        let session = makeSession(directory, runner: runner)
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)

        // 不勾任何文件：普通提交不行，amend 可以（只改信息）
        let change = try #require(session.gitSnapshot.changes.first)
        commit.setIncluded(false, for: change)
        commit.message = "x"
        #expect(!commit.canCommit)
        commit.setAmending(true)
        await waitUntil { commit.message == "上一次\n\n正文" }
        commit.message = "改过的信息"
        #expect(commit.canCommit && commit.canCommitAndPush)
        commit.commit(push: false)
        await waitUntil { commit.status != nil && !commit.isCommitting }
        // 不带 --、不 add：只改信息
        #expect(runner.calls(startingWith: "commit").last == ["commit", "--quiet", "--amend", "--only", "-m", "改过的信息"])
        #expect(runner.calls(startingWith: "add").isEmpty && runner.calls(startingWith: "rm").isEmpty)
        // 改完退出 amend、清空输入框（勾之前写的那段也不要了）
        #expect(!commit.isAmending && commit.message.isEmpty)
        if case .success(let text) = commit.status { #expect(text.contains("已修改提交") && text.contains("只改了提交信息")) } else { Issue.record("应是成功：\(String(describing: commit.status))") }

        // 勾了文件：先 add 再 commit --amend --only -- 路径
        commit.setIncluded(true, for: change)
        // 刚才那次 amend 之后 HEAD 是 h2，预填的是它的信息
        commit.setAmending(true)
        await waitUntil { commit.message == "Agent 的新提交（h2）" }
        commit.commit(push: false)
        await waitUntil { runner.calls(startingWith: "commit").count == 2 && !commit.isCommitting }
        #expect(runner.calls(startingWith: "add").last == ["add", "-A", "--", "a.txt"])
        #expect(runner.calls(startingWith: "commit").last == ["commit", "--quiet", "--amend", "--only", "-m", "Agent 的新提交（h2）", "--", "a.txt"])
    }
}

@Test @MainActor func amendingAPushedCommitWarnsAndNeverPushes() async throws {
    try await withTemporaryDirectory { directory in
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let head = Locked("h1h1h1h1h1"), remote = Locked("  origin/main\n")
        let runner = amendRunner(root: directory.resolvingSymlinksInPath().path, head: head, remoteBranches: remote)
        let session = makeSession(directory, runner: runner)
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)
        commit.setAmending(true)
        await waitUntil { commit.isAmendTargetPushed == true && commit.message == "上一次\n\n正文" }
        // 已推送：警告；「修改并推送」灰掉，只能修改
        #expect(commit.isAmendTargetPushed == true)
        #expect(commit.canCommit && !commit.canCommitAndPush)
        commit.commit(push: true)
        #expect(runner.calls(startingWith: "commit").isEmpty, "灰掉的按钮对应的动作不执行")

        // 界面上的警告还没到时点了「修改并推送」：提交前再核一次，推送过的不推
        remote.value = ""
        commit.setAmending(false)
        commit.setAmending(true)
        await waitUntil { commit.isAmendTargetPushed == false && !commit.message.isEmpty }
        remote.value = "  origin/main\n"
        commit.commit(push: true)
        await waitUntil { commit.status != nil && !commit.isCommitting }
        #expect(runner.calls(startingWith: "commit").count == 1)
        #expect(runner.calls(startingWith: "push").isEmpty)
        if case .failure(let text) = commit.status { #expect(text.contains("强制推送") && text.contains("没有自动推送")) } else { Issue.record("应提示未推送：\(String(describing: commit.status))") }

        // HEAD 变了（刚才那次 amend）：再勾上时按新 HEAD 重查
        remote.value = ""
        commit.setAmending(true)
        await waitUntil { commit.isAmendTargetPushed == false && !commit.message.isEmpty }
        #expect(commit.canCommitAndPush)
        commit.commit(push: true)
        await waitUntil { runner.calls(startingWith: "push").count == 1 }
        #expect(runner.calls(startingWith: "push").count == 1, "没推送过的照常推送")
    }
}

@Test @MainActor func amendFollowsHeadMovingUnderneathOrWarns() async throws {
    try await withTemporaryDirectory { directory in
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let head = Locked("h1h1h1h1h1"), remote = Locked("")
        let runner = amendRunner(root: directory.resolvingSymlinksInPath().path, head: head, remoteBranches: remote)
        let session = makeSession(directory, runner: runner)
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)
        commit.setAmending(true)
        await waitUntil { commit.message == "上一次\n\n正文" }
        let requests = { runner.calls(startingWith: "log").filter { $0.contains("--format=%B") }.count }
        #expect(requests() == 1)

        // Agent 在后台又提交了一次，用户没动过输入框：按新 HEAD 重新预填，不提示
        head.value = "h2h2h2h2h2"
        session.refreshGit()
        await waitUntil { commit.message == "Agent 的新提交（h2）" }
        #expect(requests() == 2)
        #expect(commit.message == "Agent 的新提交（h2）" && commit.amendTargetChangedTo == nil)

        // 用户改过输入框之后 HEAD 又变了：不替他换，提示上一次提交已经是 h3
        commit.message = "我改过的信息"
        head.value = "h3h3h3h3h3"
        session.refreshGit()
        await waitUntil { commit.amendTargetChangedTo != nil }
        #expect(commit.amendTargetChangedTo == "h3h3h3h")
        #expect(commit.message == "我改过的信息" && requests() == 2)
        // 同一个 HEAD 再刷新一次不重复处理；取消勾选提示消失、还原勾之前的文字
        let statusCalls = runner.calls(startingWith: "status").count
        session.refreshGit()
        await waitUntil { runner.calls(startingWith: "status").count > statusCalls && !session.isRefreshingGit }
        #expect(requests() == 2)
        commit.setAmending(false)
        #expect(commit.amendTargetChangedTo == nil && commit.message.isEmpty)
    }
}

@Test @MainActor func amendIsUnavailableWithoutCommits() async throws {
    try await withTemporaryDirectory { directory in
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let runner = amendRunner(root: directory.resolvingSymlinksInPath().path, head: Locked(""), remoteBranches: Locked(""), unborn: true)
        let session = makeSession(directory, runner: runner)
        await waitUntil { session.commit != nil && session.gitSnapshot.changes.count == 1 }
        let commit = try #require(session.commit)
        #expect(!commit.canAmend)
        commit.setAmending(true)
        #expect(!commit.isAmending)
        #expect(runner.calls(startingWith: "log").isEmpty)
    }
}

// MARK: - 文件历史

private let us = "\u{1f}"
private func logRecord(_ hash: String, subject: String, prefix: String = "") -> String {
    prefix + [hash, String(hash.prefix(7)), "p", "Alice", "a@x.io", "1725000000", "1725000000", subject, ""].joined(separator: us) + "\0"
}

@Test @MainActor func showHistoryFiltersTheLogAndIsExclusiveWithComparison() async throws {
    try await withTemporaryDirectory { directory in
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: directory.appendingPathComponent("src/new.swift"), atomically: true, encoding: .utf8)
        let root = directory.resolvingSymlinksInPath().path
        let runner = FakeCommandRunner { arguments, _ in
            switch arguments.first {
            case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(root + "\n")
            case "rev-parse": return shellOutput("c3c3c3c3c3\n")
            case "status": return shellOutput("# branch.oid c3c3c3c3c3\u{0}# branch.head main\u{0}")
            case "merge-base": return shellOutput("c1c1c1c1c1\n")
            case "rev-list": return shellOutput("2\n")
            case "log" where arguments.contains("--follow"):
                return shellOutput(logRecord("c3c3c3c3c3", subject: "改", prefix: "\u{1e}") + "\nM\0src/new.swift\0"
                                   + logRecord("c1c1c1c1c1", subject: "建", prefix: "\u{1e}") + "\nA\0src/old.swift\0")
            case "log" where arguments.last == "src": return shellOutput(logRecord("c3c3c3c3c3", subject: "改"))
            case "log":
                return shellOutput(logRecord("c3c3c3c3c3", subject: "改") + logRecord("c2c2c2c2c2", subject: "别的") + logRecord("c1c1c1c1c1", subject: "建"))
            case "diff" where arguments.contains("--name-status"):
                return shellOutput(arguments.last == "c1c1c1c1c1" ? "A\0a.swift\0A\0src/old.swift\0" : "M\0a.swift\0M\0src/new.swift\0")
            default: return shellOutput("")
            }
        }
        let session = makeSession(directory, runner: runner)
        await waitUntil { session.history != nil && session.gitSnapshot.branch.name == "main" }
        let history = try #require(session.history)
        let requested = Locked<ToolWindow?>(nil)
        session.onRequestToolWindow = { requested.value = $0 }
        let file = session.project.root.appendingPathComponent("src/new.swift")
        #expect(session.canShowHistory(of: file))
        #expect(!session.canShowHistory(of: session.project.root), "仓库根没有可筛的")

        // 先进比较模式，再「显示历史」：比较退出，只列动过它的提交
        session.compareWithCurrentBranch("origin/main")
        await waitUntil { history.comparison != nil && !history.isLoading }
        session.showHistory(of: file, isDirectory: false)
        #expect(requested.value == .history)
        #expect(history.comparedBranch == nil && history.comparison == nil)
        #expect(history.pathFilter?.path == "src/new.swift" && history.pathFilter?.title == "src/new.swift 的历史")
        await waitUntil { history.commits.count == 2 && !history.isLoading }
        #expect(history.commits.map(\.subject) == ["改", "建"])
        #expect(runner.calls(startingWith: "log").last?.suffix(4) == ["-n", "100", "--follow", "--", "src/new.swift"].suffix(4))
        #expect(runner.calls(startingWith: "log").last?.contains("--follow") == true)
        // 没选提交时没有详情（不是比较模式的整段）
        #expect(history.detail == nil)

        // 选中最老那个：它在那时叫 old.swift，排在最前、算「它」
        history.select(history.commits[1])
        let oldest = try #require(history.detail)
        await waitUntil { history.files[oldest.key] != nil }
        #expect(history.files(for: oldest)?.map(\.path) == ["src/old.swift", "a.swift"])
        #expect(history.isFocused(GitChange(path: "src/old.swift", kind: .added), in: oldest))
        #expect(!history.isFocused(GitChange(path: "a.swift", kind: .added), in: oldest))
        // 新的那个里叫 new.swift
        history.select(history.commits[0])
        let newest = try #require(history.detail)
        await waitUntil { history.files[newest.key] != nil }
        #expect(history.files(for: newest)?.map(\.path) == ["src/new.swift", "a.swift"])

        // HEAD 变了刷新：仍在文件历史里
        history.refresh()
        await waitUntil { !history.isLoading }
        #expect(history.pathFilter != nil && history.commits.count == 2)

        // 目录：不加 --follow
        session.showHistory(of: session.project.root.appendingPathComponent("src"), isDirectory: true)
        await waitUntil { history.commits.count == 1 && !history.isLoading }
        #expect(runner.calls(startingWith: "log").last == ["log", "--date-order", "-z", "--format=" + GitLogParser.format, "-n", "100", "--", "src"])
        #expect(history.pathFilter?.title == "src/ 的历史")

        // 反过来：文件历史里进比较模式，文件历史退出
        session.compareWithCurrentBranch("origin/main")
        #expect(history.pathFilter == nil && history.comparedBranch == "origin/main")
        await waitUntil { history.comparison != nil && !history.isLoading }
        history.exitComparison()

        // ✕ 退出文件历史：回到全部提交
        session.showHistory(of: file, isDirectory: false)
        await waitUntil { history.commits.count == 2 && !history.isLoading }
        history.exitPathHistory()
        #expect(history.pathFilter == nil)
        await waitUntil { history.commits.count == 3 && !history.isLoading }
        #expect(history.commits.map(\.subject) == ["改", "别的", "建"])
    }
}

// MARK: - 最近的文件

@Test @MainActor func recentFilesRemembersClosedFilesAcrossSessionsAndSkipsTheCurrentOne() async throws {
    try await withTemporaryDirectory { directory in
        for name in ["a.txt", "b.txt", "c.txt"] {
            try name.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let defaults = UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!
        let session = makeSession(directory, runner: nil, defaults: defaults)
        let root = session.project.root
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), c = root.appendingPathComponent("c.txt")
        session.openFile(a, pinned: true)
        session.openFile(b, pinned: true)
        session.openFile(c, pinned: true)
        // 关掉 b：仍在最近的文件里（NavigationHistory 会抹掉它，这里不会）
        session.closeTab(EditorTab.id(forFile: b))
        await waitUntil { session.tabs.count == 2 }
        #expect(session.activeTab?.fileURL == c)

        session.showRecentFiles()
        let recent = session.recentFiles
        #expect(recent.isShown)
        // 当前是 c，不列；第一项（默认选中）就是上一个文件
        #expect(recent.results.map(\.entry.path) == ["b.txt", "a.txt"])
        #expect(recent.selectedResult?.entry.path == "b.txt")
        recent.query = "a"
        #expect(recent.results.map(\.entry.path) == ["a.txt"])
        recent.query = ""
        recent.moveSelection(by: 1)
        #expect(recent.selectedResult?.entry.path == "a.txt")
        // 回车：固定标签打开，弹窗关掉；切到 a 也算「打开过」
        session.openRecentFile(try #require(recent.selectedResult))
        #expect(!recent.isShown)
        #expect(session.activeTab?.fileURL == a && session.activeTab?.isPreview == false)
        #expect(recent.store.entries.map(\.path) == ["a.txt", "c.txt", "b.txt"])

        // 重开项目（同一份 defaults）：还在；磁盘上没了的剔掉
        try FileManager.default.removeItem(at: b)
        let reopened = makeSession(directory, runner: nil, defaults: defaults)
        #expect(reopened.recentFiles.store.entries.map(\.path) == ["a.txt", "c.txt", "b.txt"])
        reopened.showRecentFiles()
        #expect(reopened.recentFiles.results.map(\.entry.path) == ["a.txt", "c.txt"])
        #expect(reopened.recentFiles.store.entries.map(\.path) == ["a.txt", "c.txt"])
        // 再按一次 ⌘E：焦点请求加一，列表照旧；Esc 关掉
        let requests = reopened.recentFiles.focusRequests
        reopened.showRecentFiles()
        #expect(reopened.recentFiles.focusRequests == requests + 1)
        reopened.recentFiles.close()
        #expect(!reopened.recentFiles.isShown)
        // 别的项目不串
        try withTemporaryDirectory { other in
            #expect(makeSession(other, runner: nil, defaults: defaults).recentFiles.store.entries.isEmpty)
        }
    }
}

@Test @MainActor func recentFilesFollowRenames() async throws {
    try await withTemporaryDirectory { directory in
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "a".write(to: directory.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let session = makeSession(directory, runner: nil)
        let root = session.project.root
        session.openFile(root.appendingPathComponent("src/a.txt"), pinned: true)
        session.openFile(root.appendingPathComponent("b.txt"), pinned: true)
        session.toggleExpanded(root.appendingPathComponent("src").path)
        let folder = try #require(session.rows.first { $0.node.name == "src" }?.node)
        session.rename(folder, to: "lib")
        await waitUntil { session.recentFiles.store.entries.map(\.path).contains("lib/a.txt") }
        #expect(session.recentFiles.store.entries.map(\.path) == ["b.txt", "lib/a.txt"])
        session.showRecentFiles()
        #expect(session.recentFiles.results.map(\.entry.path) == ["lib/a.txt"])
        // 项目根之外的文件（项目是仓库子目录，变更在外面）：算不出相对路径，跳过，不存错
        session.recentFiles.record(directory.deletingLastPathComponent().appendingPathComponent("outside.txt"))
        session.recentFiles.record(session.project.root)
        #expect(session.recentFiles.store.entries.map(\.path) == ["b.txt", "lib/a.txt"])
    }
}
