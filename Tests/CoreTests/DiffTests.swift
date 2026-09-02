import Core
import Foundation
import Testing

private let sample = """
diff --git a/Sources/App.swift b/Sources/App.swift
index 1111111..2222222 100644
--- a/Sources/App.swift
+++ b/Sources/App.swift
@@ -1,5 +1,6 @@ struct App {
 import Foundation
-let a = 1
-let b = 2
+let a = 10
+let b = 20
+let c = 30
 
 func main() {}
\\ No newline at end of file
"""

@Test func parsesUnifiedDiff() {
    let diff = UnifiedDiffParser.parse(sample)
    #expect(diff.oldPath == "Sources/App.swift")
    #expect(diff.newPath == "Sources/App.swift")
    #expect(!diff.isBinary)
    #expect(diff.hunks.count == 1)
    let hunk = diff.hunks[0]
    #expect(hunk.oldStart == 1 && hunk.oldCount == 5 && hunk.newStart == 1 && hunk.newCount == 6)
    #expect(hunk.heading == "struct App {")
    #expect(hunk.lines.count == 8)
    #expect(hunk.lines[0].kind == .context && hunk.lines[0].oldNumber == 1 && hunk.lines[0].newNumber == 1)
    #expect(hunk.lines[1].kind == .removed && hunk.lines[1].oldNumber == 2 && hunk.lines[1].newNumber == nil)
    #expect(hunk.lines[3].kind == .added && hunk.lines[3].newNumber == 2)
    #expect(hunk.lines[5].kind == .added && hunk.lines[5].text == "let c = 30" && hunk.lines[5].newNumber == 4)
    #expect(hunk.lines[6].kind == .context && hunk.lines[6].text == "" && hunk.lines[6].oldNumber == 4 && hunk.lines[6].newNumber == 5)
    #expect(hunk.lines[7].oldNumber == 5 && hunk.lines[7].newNumber == 6)
    #expect(diff.addedCount == 3)
    #expect(diff.removedCount == 2)
}

@Test func parsesNewFileAgainstDevNullAndBinary() {
    let newFile = UnifiedDiffParser.parse("""
    diff --git a/dev/null b/notes.md
    --- /dev/null
    +++ b/notes.md
    @@ -0,0 +1,2 @@
    +hello
    +world
    """)
    #expect(newFile.oldPath == nil)
    #expect(newFile.newPath == "notes.md")
    #expect(newFile.hunks[0].lines.map(\.newNumber) == [1, 2])

    let binary = UnifiedDiffParser.parse("""
    diff --git a/icon.png b/icon.png
    index 111..222 100644
    Binary files a/icon.png and b/icon.png differ
    """)
    #expect(binary.isBinary)
    #expect(binary.hunks.isEmpty)
    #expect(!binary.isEmpty)
    #expect(UnifiedDiffParser.parse("").isEmpty)
}

@Test func hunkHeaderWithoutCounts() {
    let diff = UnifiedDiffParser.parse("""
    --- a/x
    +++ b/x
    @@ -3 +3,2 @@
     a
    +b
    """)
    #expect(diff.hunks[0].oldCount == 1)
    #expect(diff.hunks[0].newCount == 2)
    #expect(diff.hunks[0].header == "@@ -3,1 +3,2 @@")
}

@Test func sideBySidePairsRemovedWithAdded() {
    let diff = UnifiedDiffParser.parse(sample)
    let rows = DiffLayout.sideBySide(diff)
    guard case .hunk(let header) = rows[0] else { Issue.record("第一行该是 hunk 头"); return }
    #expect(header.hasPrefix("@@ -1,5 +1,6 @@"))
    // 上下文 → 两个删除配两个新增 → 多出的一个新增对空白 → 上下文 × 2
    #expect(rows.count == 1 + 1 + 3 + 2)
    guard case .pair(let l1, let r1) = rows[2] else { Issue.record("应是配对行"); return }
    #expect(l1.kind == .removed && l1.text == "let a = 1" && l1.number == 2)
    #expect(r1.kind == .added && r1.text == "let a = 10" && r1.number == 2)
    guard case .pair(let l3, let r3) = rows[4] else { Issue.record("应是配对行"); return }
    #expect(l3 == DiffLayout.Cell.blank)
    #expect(r3.kind == .added && r3.text == "let c = 30" && r3.number == 4)
    guard case .pair(let l4, let r4) = rows[5] else { Issue.record("应是配对行"); return }
    #expect(l4.kind == .context && r4.kind == .context && l4.number == 4 && r4.number == 5)
}

@Test func sideBySideStartsNewGroupWhenRemovalFollowsAddition() {
    let diff = UnifiedDiffParser.parse("""
    --- a/x
    +++ b/x
    @@ -1,2 +1,2 @@
    +added first
    -removed after
     ctx
    """)
    let rows = DiffLayout.sideBySide(diff)
    #expect(rows.count == 4)
    guard case .pair(let l1, let r1) = rows[1], case .pair(let l2, let r2) = rows[2] else { Issue.record("应是配对行"); return }
    #expect(l1.kind == .empty && r1.text == "added first")
    #expect(l2.text == "removed after" && r2.kind == .empty)
}

@Test func rowsEncodeToCompactJSON() throws {
    let diff = UnifiedDiffParser.parse(sample)
    let side = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DiffLayout.sideBySide(diff))) as? [[String: Any]]
    #expect(side?.first?["type"] as? String == "hunk")
    let pair = side?[2]
    let left = pair?["l"] as? [String: Any]
    #expect(left?["k"] as? String == "del")
    #expect(left?["n"] as? Int == 2)
    #expect(left?["t"] as? String == "let a = 1")

    let unified = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DiffLayout.unified(diff))) as? [[String: Any]]
    #expect(unified?.count == 9)
    #expect(unified?.first?["text"] as? String == "@@ -1,5 +1,6 @@ struct App {")
    let added = unified?[4]
    #expect(added?["k"] as? String == "add")
    #expect(added?["n"] as? Int == 2)
    #expect(added?["o"] is NSNull || added?["o"] == nil)
}
