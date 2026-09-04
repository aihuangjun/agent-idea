import Core
import Foundation
import Testing
import TestSupport

@Test func renameValidation() {
    let existing: Set<String> = ["taken.txt", "Dir"]
    func check(_ name: String, current: String = "a.txt") -> FileRename.Problem? {
        FileRename.validate(name, currentName: current) { existing.contains($0) }
    }
    #expect(check("") == .empty)
    #expect(check("   ") == .empty)
    #expect(check("x/y") == .containsSlash)
    #expect(check("..") == .reserved)
    #expect(check("a.txt") == .unchanged)
    #expect(check("taken.txt") == .exists)
    #expect(check("Dir") == .exists)
    #expect(check("b.txt") == nil)
    #expect(check("  b.txt ") == nil, "首尾空白去掉再看")
    // 只改大小写：不分大小写的文件系统会说目标已存在，得放行
    #expect(FileRename.validate("A.TXT", currentName: "a.txt") { _ in true } == nil)
}

@Test func renameEditableRangeSelectsStem() {
    func selected(_ name: String) -> String { String(name[FileRename.editableRange(of: name)]) }
    #expect(selected("main.swift") == "main")
    #expect(selected("archive.tar.gz") == "archive.tar")
    #expect(selected(".env") == ".env")
    #expect(selected("Makefile") == "Makefile")
    #expect(selected("dir.name") == "dir")
    #expect(String("v1.2"[FileRename.editableRange(of: "v1.2", isDirectory: true)]) == "v1.2", "目录没有扩展名的概念，全选")
}

@Test func renameRewritesPathsUnderTheOldOne() {
    #expect(FileRename.rewrite("/p/a", from: "/p/a", to: "/p/b") == "/p/b")
    #expect(FileRename.rewrite("/p/a/x/y.txt", from: "/p/a", to: "/p/b") == "/p/b/x/y.txt")
    #expect(FileRename.rewrite("/p/ab", from: "/p/a", to: "/p/b") == nil, "同前缀但不是子路径")
    #expect(FileRename.rewrite("/p/c", from: "/p/a", to: "/p/b") == nil)
}

@Test func flattenedTreeRenameMovesExpansionAndDropsStaleChildren() {
    var tree = FlattenedTree()
    let node = { (path: String, directory: Bool) in FileNode(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isDirectory: directory) }
    tree.setChildren([node("/r/a", true), node("/r/z.txt", false)], for: "/r")
    tree.setChildren([node("/r/a/b", true)], for: "/r/a")
    tree.setChildren([node("/r/a/b/c.txt", false)], for: "/r/a/b")
    tree.expand("/r/a")
    tree.expand("/r/a/b")

    tree.rename("/r/a", to: "/r/n")
    #expect(tree.isExpanded("/r/n") && tree.isExpanded("/r/n/b"))
    #expect(!tree.isExpanded("/r/a"))
    #expect(!tree.hasLoaded("/r/a") && !tree.hasLoaded("/r/a/b"), "旧路径下的缓存作废")
    #expect(!tree.hasLoaded("/r"), "父目录要重列")
    #expect(Set(tree.needsLoading(root: "/r")) == ["/r", "/r/n", "/r/n/b"])
}

@Test func navigationHistoryReplaceKeepsPosition() {
    var history = NavigationHistory<String>()
    history.visit("a")
    history.visit("b")
    history.visit("a")
    _ = history.goBack()
    history.replace("a", with: "c")
    #expect(history.entries == ["c", "b", "c"])
    #expect(history.current == "b")
    #expect(history.goBack() == "c")
}
