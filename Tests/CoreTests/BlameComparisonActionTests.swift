import Core
import Foundation
import Testing
import TestSupport

@Test func blameParsesOriginalPathLineAndUncommittedBuffer() throws {
    let hash = String(repeating: "a", count: 40)
    let initial = """
    \(hash) 12 3 2
    author Alice Chen
    author-time 1725000000
    summary Move files: keep context
    filename "old/\u{5c}344\u{5c}270\u{5c}255\u{5c}tspace.swift"
    \tlet value = 1
    \(String(repeating: "0", count: 40)) 4 4 1
    author Not Committed Yet
    summary Uncommitted changes
    filename src/new.swift
    \tlet value = 2
    """
    let lines = GitBlameParser.parse(initial)
    #expect(lines.count == 2)
    let first = try #require(lines.first)
    #expect(first.hash == hash && first.originalLine == 12 && first.line == 3)
    #expect(first.path == "old/中\tspace.swift")
    #expect(first.summary == "Move files: keep context" && first.author == "Alice Chen")
    #expect(first.date == Date(timeIntervalSince1970: 1_725_000_000))
    #expect(lines.last?.hash == nil && lines.last?.path == "src/new.swift")
}

@Test func arbitraryComparisonUsesDraftAndNormalizesLineEndings() throws {
    try withTemporaryDirectory { root in
        let left = root.appendingPathComponent("a.swift")
        let right = root.appendingPathComponent("b.swift")
        try Data("same\r\nold\r\n".utf8).write(to: left)
        try Data("same\nnew\n".utf8).write(to: right)
        #expect(try FileComparison.read(.file(left, draft: nil), .file(right, draft: nil)) == .text("same\nold\n", "same\nnew\n"))
        #expect(try FileComparison.read(.file(left, draft: "draft\n"), .clipboard("pasted\r\n")) == .text("draft\n", "pasted\n"))
        let bin = root.appendingPathComponent("a.bin")
        try Data([0, 1, 2]).write(to: bin)
        #expect(try FileComparison.read(.file(bin, draft: nil), .file(bin, draft: nil)) == .binary(identical: true))
        #expect(throws: FileComparison.Error.self) { _ = try FileComparison.read(.file(bin, draft: nil), .clipboard("text")) }
        #expect(throws: FileComparison.Error.self) { _ = try FileComparison.read(.file(root, draft: nil), .file(right, draft: nil)) }
    }
}

@Test func actionSearchRanksTitleAndAcceptsAliasesAndShortcuts() {
    let entries: [ActionSearch.Entry] = [
        .init(id: "recent", title: "最近的位置…", location: "导航", shortcut: "⇧⌘E", keywords: "最近文件 history", enabled: true),
        .init(id: "files", title: "最近文件…", location: "导航", shortcut: "⌘E", keywords: "recent files", enabled: true),
        .init(id: "blame", title: "显示 Git 行归属", location: "Git", shortcut: nil, keywords: "git blame annotate", enabled: false),
    ]
    #expect(ActionSearch.matching("最近文件", in: entries).map(\.id) == ["files", "recent"])
    #expect(ActionSearch.matching("Git BLAME", in: entries).map(\.id) == ["blame"])
    #expect(ActionSearch.matching("⇧⌘E", in: entries).map(\.id) == ["recent"])
    #expect(ActionSearch.matching("not present", in: entries).isEmpty)
}
