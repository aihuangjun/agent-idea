import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@testable import Workbench

@Test @MainActor func diffReadingPreferencesPersistAndProgressUsesNavigationOrder() {
    let name = "diff-review-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = ReadingPreferences(defaults: defaults)
    #expect(preferences.diffReading.collapseUnchanged)
    #expect(preferences.diffReading.contextLines == 10)
    preferences.diffReading = .init(collapseUnchanged: false, contextLines: 30, whitespace: .trailing)
    #expect(ReadingPreferences(defaults: defaults).diffReading == preferences.diffReading)
    let session = ProjectSession(root: URL(fileURLWithPath: "/tmp"), git: nil, renderer: ContentRenderer(), preferences: preferences)
    defer { session.tearDown() }
    #expect(session.diffReviewProgress.fileCount == 0 && session.diffReviewProgress.changeCount == 0)
    session.setChangePosition(.init(hasPrevious: true, hasNext: true, index: 2, total: 5))
    #expect(session.diffReviewProgress.changeIndex == 2 && session.diffReviewProgress.changeCount == 5)
}

@Test func historicalDiffLoadsBothCompleteVersionsAndKeepsReadOnlyContract() async throws {
    let original = (0..<100).map { "original \($0)\n" }.joined()
    let current = original.replacingOccurrences(of: "original 50", with: "changed 50")
    let runner = FakeCommandRunner { arguments, _ in
        if arguments.first == "diff" { return shellOutput("--- a/old.txt\n+++ b/new.txt\n@@ -51 +51 @@\n-original 50\n+changed 50\n") }
        if arguments == ["show", "parent:old.txt"] { return shellOutput(original) }
        if arguments == ["show", "commit:new.txt"] { return shellOutput(current) }
        return shellOutput("", status: 128)
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let commit = GitCommit(hash: "commit", shortHash: "commit", parents: ["parent"], authorName: "", authorEmail: "", authorDate: Date(), subject: "", body: "")
    let change = GitChange(path: "new.txt", originalPath: "old.txt", kind: .renamed)
    let content = await FileContentLoader.loadDiff(change, in: commit, git: git, repositoryRoot: URL(fileURLWithPath: "/repo"))
    guard case .textDiff(let old, let new, _) = content else { Issue.record("历史 diff 必须包含全文"); return }
    #expect(old == original && new == current)
    let tab = EditorTab(kind: .commitDiff(commit, change), isPreview: true)
    if case .diff(_, _, _, _, _, let edit?) = content.renderContent(for: tab, diffMode: .sideBySide) {
        #expect(edit.readOnly && edit.oldText == original && edit.newText == current)
    } else { Issue.record("缺少只读全文渲染契约") }
}
