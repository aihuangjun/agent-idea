import Core
import Foundation
import Testing
import TestSupport

@Test func replacementUsesUTF16CapturesAndHonorsSelectionEdges() throws {
    let text = "🌿cat-a\ncat-b\ncat-aa\nconcatenate cat-c"
    let query = TextSearchQuery(text: #"\bcat-([a-z])\b"#, isRegex: true)
    let matcher = try TextSearchMatcher(query)
    let edits = matcher.replacements(in: text, template: "$1-dog", interpretingGroups: true, within: 2..<16)
    #expect(edits.map(\.start) == [2, 8])
    #expect(TextReplacement.apply(edits, to: text) == "🌿a-dog\nb-dog\ncat-aa\nconcatenate cat-c")
    #expect(TextReplacement.apply([.init(start: 1, length: 1, text: "x"), .init(start: 0, length: 1, text: "y")], to: "abc") == nil)
    let boundaries = try TextSearchMatcher(TextSearchQuery(text: "cat", wholeWords: true))
    #expect(boundaries.replacements(in: "bobcat", template: "dog", interpretingGroups: false, within: 3..<6).isEmpty)
    let anchors = try TextSearchMatcher(TextSearchQuery(text: "^cat", isRegex: true))
    #expect(anchors.replacements(in: text, template: "dog", interpretingGroups: true).map(\.start) == [8, 14])
}

@Test func crossFileReplacementRequiresFreshPreviewAndCanUndoAsUnit() throws {
    try withTemporaryDirectory { root in
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        let originalA = "token one\r\ntoken two\n"
        let originalB = "🌿 token three\n"
        try Data(originalA.utf8).write(to: a)
        try Data(originalB.utf8).write(to: b)
        try FileManager.default.setAttributes([.posixPermissions: 0o744], ofItemAtPath: a.path)
        let query = TextSearchQuery(text: "token", caseSensitive: true)
        let matcher = try TextSearchMatcher(query)
        let preview = FileReplacement.preview(root: root, paths: ["a.txt", "b.txt"], query: query, matcher: matcher, template: "new", limit: 12)
        #expect(preview.files.first?.previewLines().map(\.line) == [1, 2])
        let rows = preview.files.flatMap { $0.previewLines() }
        #expect(Set(rows.map(\.id)).count == 3)
        let changes = preview.files.compactMap { $0.change(selecting: [0]) }
        #expect(changes.count == 2)
        try Data("updated".utf8).write(to: b)
        #expect(throws: TextSearchError.self) { try FileTextTransaction.write(changes, under: root) }
        #expect(try String(contentsOf: a, encoding: .utf8) == originalA)
        try Data(originalB.utf8).write(to: b)

        try FileTextTransaction.write(changes, under: root)
        #expect(try String(contentsOf: a, encoding: .utf8) == "new one\r\ntoken two\n")
        #expect(try String(contentsOf: b, encoding: .utf8) == "🌿 new three\n")
        #expect(try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int == 0o744)
        try FileTextTransaction.write(changes, under: root, reversing: true)
        #expect(try String(contentsOf: a, encoding: .utf8) == originalA)
        #expect(try String(contentsOf: b, encoding: .utf8) == originalB)
    }
}

@Test func renameTransactionMovesSourceAndRejectsOccupiedDestination() throws {
    try withTemporaryDirectory { root in
        let source = root.appendingPathComponent("Old.java"), destination = root.appendingPathComponent("New.java")
        let before = Data("class Old {}".utf8), after = Data("class New {}".utf8)
        try before.write(to: source)
        try Data("untouched".utf8).write(to: destination)
        let changes = [FileTextTransaction.Change(path: "Old.java", before: before, after: after, newPath: "New.java")]
        #expect(throws: TextSearchError.self) { try FileTextTransaction.write(changes, under: root) }
        #expect(try Data(contentsOf: source) == before)
        try FileManager.default.removeItem(at: destination)
        try FileTextTransaction.write(changes, under: root)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == after)
        try FileTextTransaction.write(changes, under: root, reversing: true)
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
