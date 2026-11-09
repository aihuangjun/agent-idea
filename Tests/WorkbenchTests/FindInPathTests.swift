import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

@MainActor private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// 造一条 `git grep -n --column -z` 的记录。
private func record(_ path: String, _ line: Int, _ column: Int, _ text: String) -> String {
    "\(path)\u{0}\(line)\u{0}\(column)\u{0}\(text)\n"
}

/// 「slow」那一次挂起直到被取消（模拟大仓库里还没搜完就又敲了一个字），别的照常返回。
private final class GatedRunner: CommandRunning, @unchecked Sendable {
    let slowWasCancelled = Locked(false)
    let calls = Locked<[[String]]>([])
    private let pending = Locked<CheckedContinuation<Void, Never>?>(nil)

    func run(executable: URL, arguments: [String], currentDirectory: URL?, environment: [String: String]?) async throws -> ShellOutput {
        calls.value.append(arguments)
        if arguments.contains("slow") {
            // 不轮询、不定时：挂在 continuation 上，取消时由 onCancel 放行
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    pending.value = continuation
                    if Task.isCancelled { pending.value = nil; continuation.resume() }
                }
            } onCancel: {
                let continuation = pending.value
                pending.value = nil
                continuation?.resume()
            }
            slowWasCancelled.value = true
            throw CancellationError()
        }
        return shellOutput(record("fast.txt", 1, 1, "fast"))
    }
}

/// 控制器：参数照查询构造、在项目根里跑；结果按文件分组、默认选第一处；↑ ↓ 跳过折叠的文件；
/// 正则写错马上提示且不去问 git；清空查询清掉结果。
@Test @MainActor func findInPathRunsGitGrepInTheProjectAndNavigatesResults() async throws {
    let output = record("Sources/A.swift", 3, 5, "let needle = needle") + record("Sources/A.swift", 9, 1, "needle()") + record("B.md", 1, 4, "a needle")
    let runner = FakeCommandRunner { _, _ in shellOutput(output) }
    let controller = TextSearchController(root: URL(fileURLWithPath: "/p"), git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), debounce: 0)

    controller.text = "needle"
    await waitUntil { controller.result != nil }
    let call = try #require(runner.calls.last)
    #expect(call.directory == "/p", "在项目根里跑，路径直接相对项目根")
    #expect(call.arguments.starts(with: ["-c", "grep.fullName=false", "-c", "grep.fallbackToNoIndex=false", "grep", "--untracked", "-I", "-n", "--column", "-z", "--no-color", "-i", "-F", "-e", "needle"]))
    let result = try #require(controller.result)
    #expect(result.files.map(\.path) == ["Sources/A.swift", "B.md"])
    #expect(result.matchCount == 4)
    #expect(controller.selected == .init(path: "Sources/A.swift", line: 3), "默认选第一处，回车就能打开")
    #expect(!controller.isSearching)

    controller.moveSelection(by: 1)
    #expect(controller.selected == .init(path: "Sources/A.swift", line: 9))
    controller.moveSelection(by: 1)
    #expect(controller.selected == .init(path: "B.md", line: 1))
    controller.moveSelection(by: 1)
    #expect(controller.selected == .init(path: "B.md", line: 1), "到头不动")
    controller.toggleCollapsed("Sources/A.swift")
    controller.moveSelection(by: -1)
    #expect(controller.selected == .init(path: "B.md", line: 1), "折叠的文件里的行跳过")
    controller.expandAll()
    controller.moveSelection(by: -2)
    #expect(controller.selected == .init(path: "Sources/A.swift", line: 3))

    // 选项变了重新搜，参数跟着变
    controller.caseSensitive = true
    controller.fileMask = "*.swift"
    await waitUntil { runner.calls.last?.arguments.contains(":(glob,icase)**/*.swift") == true }
    #expect(runner.calls.last?.arguments.contains("-i") == false)
    #expect(controller.selected == .init(path: "Sources/A.swift", line: 3), "同一处还在就保留选中")

    // 正则写错：马上提示，不去问 git
    let callsBefore = runner.calls.count
    controller.isRegex = true
    controller.text = "needle("
    #expect(controller.error?.contains("圆括号") == true)
    #expect(controller.result == nil)
    #expect(!controller.isSearching)
    #expect(runner.calls.count == callsBefore)

    controller.text = ""
    #expect(controller.error == nil)
    #expect(controller.result == nil)
    #expect(controller.selected == nil)
}

/// 新的一次搜索取消上一次：被顶掉的那次不报错、结果不会回头盖掉新的。
@Test @MainActor func aNewSearchCancelsThePreviousOneSilently() async throws {
    let runner = GatedRunner()
    let controller = TextSearchController(root: URL(fileURLWithPath: "/p"), git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), debounce: 0)
    controller.text = "slow"
    await waitUntil { runner.calls.value.count == 1 }
    #expect(controller.isSearching)
    controller.text = "fast"
    await waitUntil { runner.slowWasCancelled.value && controller.result != nil }
    #expect(runner.slowWasCancelled.value, "上一次的 git grep 被取消")
    #expect(controller.result?.files.map(\.path) == ["fast.txt"])
    #expect(controller.error == nil, "取消不当失败")
    #expect(!controller.isSearching)
}

/// 不在 git 仓库里（本机没有 git，或 git 说 not a git repository）：逐个读文件搜，二进制跳过。
@Test @MainActor func findInPathFallsBackToScanningFilesOutsideGit() async throws {
    try await withTemporaryDirectory { directory in
        try "alpha\nthe needle here\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "needle needle".write(to: directory.appendingPathComponent("sub/b.swift"), atomically: true, encoding: .utf8)
        try Data([0, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: directory.appendingPathComponent("blob.bin"))

        let noGit = TextSearchController(root: directory, git: nil, debounce: 0)
        noGit.text = "needle"
        await waitUntil { noGit.result != nil }
        #expect(noGit.result?.files.map(\.path) == ["a.txt", "sub/b.swift"])
        #expect(noGit.result?.matchCount == 3)

        let runner = FakeCommandRunner { _, _ in shellOutput("", status: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git") }
        let outside = TextSearchController(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), debounce: 0)
        outside.text = "needle"
        await waitUntil { outside.result != nil || outside.error != nil }
        #expect(outside.error == nil)
        #expect(outside.result?.files.map(\.path) == ["a.txt", "sub/b.swift"])
    }
}

/// 会话：⌃⇧F 切到「查找」窗口并拿编辑器里的单行选区预填；打开一处结果跳到那一行、把命中的文字选上（列按 UTF-16）。
@Test @MainActor func findInPathPrefillsFromTheEditorAndOpensResultsWithTheMatchSelected() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.swift")
        try (1...80).map { $0 == 50 ? "    😀中 call(needle)" : "let value\($0) = \($0)" }.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let suite = "agentidea-find-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: nil, renderer: renderer, preferences: ReadingPreferences(defaults: defaults))
        var requested: ToolWindow?
        session.onRequestToolWindow = { requested = $0 }
        session.setActive(true)
        defer { session.tearDown() }

        session.openFile(file, pinned: true)
        func selection() async -> String {
            let value = try? await renderer.webView.evaluateJavaScript("""
            (() => { const cm = document.querySelector('.CodeMirror'); if (!cm) return '';
              const c = cm.CodeMirror; return c.getSelection() + '@' + c.getCursor('from').line + ':' + c.getCursor('from').ch; })()
            """)
            return value as? String ?? ""
        }
        await waitUntil { await selection() == "@0:0" }
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setSelection({line: 2, ch: 4}, {line: 2, ch: 11}); true")

        let focusBefore = session.textSearch.focusRequests
        session.showFindInPath()
        #expect(requested == .find)
        await waitUntil { session.textSearch.text == "value3 " && session.textSearch.focusRequests > focusBefore }
        #expect(session.textSearch.text == "value3 ", "单行选区原样预填")

        // 多行选区不预填，输入框里原来的留着
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setSelection({line: 2, ch: 0}, {line: 4, ch: 0}); true")
        let focusAgain = session.textSearch.focusRequests
        session.showFindInPath()
        await waitUntil { session.textSearch.focusRequests > focusAgain }
        #expect(session.textSearch.text == "value3 ")

        session.textSearch.text = "NEEDLE"
        await waitUntil(15) { session.textSearch.result?.files.isEmpty == false }
        let hit = try #require(session.textSearch.selected)
        #expect(hit == .init(path: "a.swift", line: 50))
        let line = try #require(session.textSearch.line(for: hit))
        #expect(line.column == 13, "4 个空格 + 😀（2）+ 中 + 空格 + call( → UTF-16 的 13")

        // 先切到别的位置，再打开结果：跳回第 50 行并选中命中
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror').CodeMirror.setCursor({line: 0, ch: 0}); true")
        session.openSearchResult(path: hit.path, line: line, pinned: false)
        await waitUntil { await selection() == "needle@49:13" }
        #expect(await selection() == "needle@49:13", "已经开着的文件直接跳，命中的文字选上")
        #expect(renderer.lastPayload?.revealLine == nil, "直接跳不经过 payload")

        // 没开着的文件：在打开的那一次渲染里带着跳与选中
        session.closeAllTabs()
        // 当前的可编辑标签先向页面要一次状态才关，是异步的
        await waitUntil { session.tabs.isEmpty }
        session.openSearchResult(path: hit.path, line: line, pinned: false)
        #expect(session.activeTab?.isPreview == true, "单击用预览标签")
        await waitUntil { await selection() == "needle@49:13" }
        #expect(await selection() == "needle@49:13")
        #expect(renderer.lastPayload?.revealLength == 6, "跳与选中随打开的那一次渲染送进去")
    }
}

/// 「查找」窗口的冒烟：有结果（含 emoji、长行、出错提示）时整个视图在离屏窗口里排得出来、画得出来。
/// 行的点击与 `ChangesView` 同一套 `PressGesture`，那边的离屏点击测试守着。
@Test @MainActor func findInPathViewLaysOutWithResults() async throws {
    try await withTemporaryDirectory { directory in
        let long = String(repeating: "x", count: 400) + " needle " + String(repeating: "y", count: 400)
        let output = record("Sources/A.swift", 3, 5, "    😀 let needle = needle") + record("B.md", 1, 403, long)
        let runner = FakeCommandRunner { arguments, _ in
            arguments.contains("grep") ? shellOutput(output) : shellOutput("", status: 128, stderr: "fatal: not a git repository")
        }
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        defer { session.tearDown() }
        session.textSearch.text = "needle"
        await waitUntil { session.textSearch.result != nil }
        #expect(session.textSearch.result?.matchCount == 3)

        let size = CGSize(width: 320, height: 400)
        let hosting = NSHostingView(rootView: FindInPathView(session: session).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)

        // 折叠、出错的样子也画一遍
        session.textSearch.collapseAll()
        session.textSearch.isRegex = true
        session.textSearch.text = "needle("
        #expect(session.textSearch.error != nil)
        hosting.layoutSubtreeIfNeeded()
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
    }
}

/// git 说过一次「不在仓库里」，之后的搜索直接逐个读文件，不再每次先起 git。
@Test @MainActor func findInPathRemembersTheProjectIsOutsideGit() async throws {
    try await withTemporaryDirectory { directory in
        try "needle".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "needle".write(to: directory.appendingPathComponent(".build/out.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("web/node_modules/x"), withIntermediateDirectories: true)
        try "needle".write(to: directory.appendingPathComponent("web/node_modules/x/i.js"), atomically: true, encoding: .utf8)
        try "needle".write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let runner = FakeCommandRunner { _, _ in shellOutput("", status: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git") }
        let controller = TextSearchController(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), debounce: 0)
        controller.text = "needle"
        await waitUntil { controller.result != nil }
        #expect(controller.result?.files.map(\.path) == [".env", "a.txt"], "隐藏目录与 node_modules 不进去，隐藏文件照搜")
        #expect(runner.calls.count == 1)
        controller.text = "need"
        await waitUntil { controller.result?.matchCount == 2 && !controller.isSearching }
        #expect(controller.result?.files.map(\.path) == [".env", "a.txt"])
        #expect(runner.calls.count == 1, "第二次不再先问 git")
    }
}

/// 「查找」工具窗口能存进偏好再读回来；老版本存下的 project / commit / history 照常认。
@Test @MainActor func findToolWindowPersists() async throws {
    try await withTemporaryDirectory { directory in
        let suite = "agentidea-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = directory.appendingPathComponent("recent.json")
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: recent)
        workbench.toolWindow = .find
        #expect(defaults.string(forKey: "toolWindow") == "find")
        #expect(WorkbenchModel(git: nil, defaults: defaults, recentFile: recent).toolWindow == .find)
        for (saved, expected) in [("project", ToolWindow.project), ("commit", .commit), ("history", .history)] {
            defaults.set(saved, forKey: "toolWindow")
            #expect(WorkbenchModel(git: nil, defaults: defaults, recentFile: recent).toolWindow == expected, "\(saved)")
        }
        defaults.set("", forKey: "toolWindow")
        #expect(WorkbenchModel(git: nil, defaults: defaults, recentFile: recent).toolWindow == nil, "收起的照旧是收起")
    }
}
