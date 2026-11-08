import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@preconcurrency import WebKit
@testable import Workbench

@MainActor private func waitForDiff(_ description: String = "", _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("等待 diff 导航完成超时：\(description)")
}

@MainActor private func diffLine(_ renderer: ContentRenderer) async throws -> Int {
    let value = try await renderer.webView.evaluateJavaScript("window.ide?.getState().cursor?.line ?? -1")
    return (value as? NSNumber)?.intValue ?? -1
}

@Test @MainActor func arrowNavigationCrossesFilesAtTheCorrectEdgeAndPreservesDrafts() async throws {
    try await withTemporaryDirectory { directory in
        let old = (0..<120).map { "line \($0)" }.joined(separator: "\n")
        for mode in DiffViewMode.allCases {
            for (name, changes) in [("a.txt", [20, 80]), ("b.txt", [30, 70])] {
                var lines = old.components(separatedBy: "\n")
                for line in changes { lines[line] = "changed \(line)" }
                try lines.joined(separator: "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let runner = FakeCommandRunner { arguments, _ in
                switch arguments.first {
                case "rev-parse" where arguments.contains("--show-toplevel"): return shellOutput(directory.path)
                case "rev-parse": return shellOutput("head")
                case "status": return shellOutput("# branch.oid head\0# branch.head main\01 .M N... 100644 100644 100644 a b a.txt\01 .M N... 100644 100644 100644 a b b.txt\0")
                case "show": return shellOutput(old)
                case "diff": return shellOutput("2\t2\ta.txt\02\t2\tb.txt\0")
                default: return shellOutput("")
                }
            }
            let suite = "agentidea-navigation-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = ReadingPreferences(defaults: defaults)
            preferences.diffMode = mode
            let renderer = ContentRenderer()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = renderer.webView
            let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: renderer, preferences: preferences)
            renderer.onEdited = { [weak session] path, text in session?.applyEdit(path: path, text: text) }
            renderer.onDiffNavigate = { [weak session] step, path in
                guard session?.activeTab?.diffChange?.path == path else { return }
                session?.navigateChange(step)
            }
            renderer.onChangePosition = { [weak session] in session?.setChangePosition($0) }
            renderer.onDiffStatistics = { [weak session] path, counts in session?.updateDiffStatistics(path: path, counts: counts) }
            session.setActive(true)
            defer { session.tearDown() }
            try await waitForDiff { session.changeGroups.total == 2 && session.diffStatistics.count == 2 }
            session.openDiff(try #require(session.gitSnapshot.changes.first { $0.path == "a.txt" }))
            try await waitForDiff { try await diffLine(renderer) == 20 }
            #expect(!session.canNavigateChange(.previous))

            @MainActor func press(_ key: String, path: String, line: Int) async throws {
                _ = try await renderer.webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(key)', bubbles: true, cancelable: true})); true")
                try await waitForDiff {
                    guard session.activeTab?.diffChange?.path == path else { return false }
                    return try await diffLine(renderer) == line
                }
                #expect(session.diffReviewProgress.fileCount == 2)
                #expect(session.diffReviewProgress.fileIndex == (path == "a.txt" ? 1 : 2))
                #expect(session.diffReviewProgress.changeCount == 2)
                #expect(session.diffReviewProgress.changeIndex == ([20, 30].contains(line) ? 1 : 2))
            }
            try await press("ArrowDown", path: "a.txt", line: 80)
            _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror.replaceRange('DRAFT_', {line: 80, ch: 0}); true")
            try await press("ArrowDown", path: "b.txt", line: 30)
            let aligned = try await renderer.webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('.CodeMirror')).every(node => {
              const gutter = node.querySelector('.CodeMirror-gutters').getBoundingClientRect();
              return Array.from(node.querySelectorAll('pre.CodeMirror-line')).every(pre => {
                const text = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT).nextNode();
                if (!text || !text.textContent.startsWith('line ')) return true;
                const range = document.createRange(); range.setStart(text, 0); range.setEnd(text, 1);
                return range.getBoundingClientRect().left >= gutter.right - 1;
              });
            })
            """)
            #expect(aligned as? Bool == true, "跨文件后上下文不能被行号覆盖")
            try await press("ArrowUp", path: "a.txt", line: 80)
            let draft = try await renderer.webView.evaluateJavaScript("window.ide.getState().text.includes('DRAFT_changed 80')")
            #expect(draft as? Bool == true, "跨文件导航必须收取编辑器里的最新草稿：\(mode)")
            try await press("ArrowUp", path: "a.txt", line: 20)
            try await press("ArrowDown", path: "a.txt", line: 80)
            try await press("ArrowDown", path: "b.txt", line: 30)
            try await press("ArrowDown", path: "b.txt", line: 70)
            #expect(!session.canNavigateChange(.next))
            #expect(session.diffStatistics["a.txt"] == DiffLineCounts(added: 2, removed: 2))
            _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.CodeMirror-merge-editor .CodeMirror, .diff-host .CodeMirror').CodeMirror.replaceRange('line 70', {line: 70, ch: 0}, {line: 70, ch: 10}); true")
            try await waitForDiff("未保存编辑的行数统计") { session.diffStatistics["b.txt"] == DiffLineCounts(added: 1, removed: 1) }
        }
    }
}

@Test @MainActor func historyNavigationStaysInsideTheCommitAndEntersTheLastChangeBackwards() async throws {
    try await withTemporaryDirectory { directory in
        let patch = "--- a/file\n+++ b/file\n@@ -10,3 +10,3 @@\n-old first\n+new first\n context\n context\n@@ -30,3 +30,3 @@\n-old last\n+new last\n context\n context\n"
        let runner = FakeCommandRunner { arguments, _ in
            if arguments.first == "rev-parse" { return shellOutput(arguments.contains("--show-toplevel") ? directory.path : "head") }
            if arguments.first == "diff", arguments.contains("--name-status") { return shellOutput("M\0z.txt\0M\0a.txt\0") }
            if arguments.first == "diff", arguments.contains("--numstat") { return shellOutput("2\t2\tz.txt\02\t2\ta.txt\0") }
            if arguments.first == "diff" { return shellOutput(patch) }
            if arguments.first == "show" { return shellOutput("", status: 128, stderr: "object unavailable") }
            return shellOutput("")
        }
        let renderer = ContentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        let session = ProjectSession(root: directory, git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner), renderer: renderer,
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        session.setActive(true)
        defer { session.tearDown() }
        try await waitForDiff("历史控制器初始化") { session.history != nil }
        let commit = GitCommit(hash: "commit", shortHash: "commit", parents: ["parent"], authorName: "", authorEmail: "", authorDate: Date(), subject: "", body: "")
        let history = try #require(session.history)
        history.select(commit)
        try await waitForDiff("历史文件和统计加载") { history.statisticsByCommit[commit.id]?.count == 2 }
        session.openCommitDiff(try #require(history.filesByCommit[commit.id]?.last), in: commit)
        try await waitForDiff("历史文件第一处差异") { (try? await renderer.webView.evaluateJavaScript("document.querySelector('tr.current-change td.src')?.textContent.includes('first')")) as? Bool == true }
        session.navigateChange(.previous)
        try await waitForDiff("上个历史文件最后一处差异") {
            guard session.activeTab?.diffChange?.path == "a.txt" else { return false }
            return (try? await renderer.webView.evaluateJavaScript("document.querySelector('tr.current-change td.src')?.textContent.includes('last')")) as? Bool == true
        }
        let diagnostic = try? await renderer.webView.evaluateJavaScript("JSON.stringify({height: innerHeight, top: scrollY, selected: Array.from(document.querySelectorAll('tr.current-change td.src')).map(x => x.textContent), rows: Array.from(document.querySelectorAll('tr.changed')).map(x => x.getBoundingClientRect().top)})")
        #expect(session.activeTab?.diffChange?.path == "a.txt", "\(String(describing: diagnostic))")
        #expect((diagnostic as? String)?.contains("last") == true, "\(String(describing: diagnostic))")
        #expect(session.activeTab?.commitDiff?.commit.hash == commit.hash)
        #expect(history.statisticsByCommit[commit.id]?["z.txt"] == DiffLineCounts(added: 2, removed: 2))
        _ = window.contentView
    }
}
