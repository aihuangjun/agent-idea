import Core
import Testing

@Test func changeTreePreservesDirectoriesAndNaturalOrder() {
    let changes = [
        GitChange(path: "README.md", kind: .modified),
        GitChange(path: "src/UI2/same.swift", kind: .modified),
        GitChange(path: "src/UI10/same.swift", kind: .deleted),
        GitChange(path: "src/UI2/new.swift", originalPath: "old/file.swift", kind: .renamed),
        GitChange(path: "src/root.swift", kind: .added),
    ]
    let tree = GitChangeTree(changes: changes.reversed())
    #expect(tree.rows.map(\.path) == ["src", "src/UI2", "src/UI2/new.swift", "src/UI2/same.swift", "src/UI10", "src/UI10/same.swift", "src/root.swift", "README.md"])
    #expect(tree.rows.map(\.depth) == [0, 1, 2, 2, 1, 2, 1, 0])
    #expect(tree.rows.first?.changes.count == 4)
    #expect(tree.rows[1].changes.map(\.path) == ["src/UI2/new.swift", "src/UI2/same.swift"])
    #expect(tree.rows[2].change?.originalPath == "old/file.swift")
    #expect(tree.rows[5].change?.kind == .deleted)
    #expect(GitChangeTree(changes: []).rows.isEmpty)
}

@Test func changeTreeCollapseDeterminesVisibleSelectionOrder() {
    let changes = ["a/inner/one.txt", "a/two.txt", "ab/three.txt", "root.txt"].map { GitChange(path: $0, kind: .modified) }
    let tree = GitChangeTree(changes: changes)
    #expect(tree.visibleRows(collapsedDirectories: ["a"]).map(\.path) == ["a", "ab", "ab/three.txt", "root.txt"])
    #expect(tree.visibleRows(collapsedDirectories: ["a/inner"]).compactMap { $0.change?.path } == ["a/two.txt", "ab/three.txt", "root.txt"])
    #expect(tree.visibleRows(collapsedDirectories: ["a", "a/inner", "ab"]).compactMap { $0.change?.path } == ["root.txt"])
    #expect(tree.visibleRows(collapsedDirectories: ["obsolete"]) == tree.rows)
    #expect(tree.rows.first?.changes.count == 2, "折叠不改变目录的勾选范围")
}

@Test func changeTreeKeepsFileAndDirectoryReplacementDistinct() {
    let tree = GitChangeTree(changes: [GitChange(path: "a", kind: .deleted), GitChange(path: "a/b", kind: .added)])
    #expect(tree.rows.map(\.path) == ["a", "a/b", "a"])
    #expect(Set(tree.rows.map(\.id)).count == 3)
    #expect(tree.visibleRows(collapsedDirectories: ["a"]).compactMap { $0.change?.path } == ["a"])
}
