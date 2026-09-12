import Core
import Foundation
import Testing

@Test func treeSelectionClickToggleAndExtend() {
    let order = ["/p/a", "/p/b", "/p/c", "/p/d", "/p/e"]
    var selection = TreeSelection()
    #expect(selection.isEmpty)
    selection.select("/p/b")
    #expect(selection.anchor == "/p/b" && selection.paths == ["/p/b"])

    // ⌘点击加一个、再去掉一个
    selection.toggle("/p/d", order: order)
    #expect(selection.anchor == "/p/d" && selection.paths == ["/p/b", "/p/d"])
    selection.toggle("/p/d", order: order)
    #expect(selection.anchor == "/p/b" && selection.paths == ["/p/b"], "去掉锚点后锚点落到剩下的最靠前那个")
    selection.toggle("/p/b", order: order)
    #expect(selection.isEmpty && selection.anchor == nil)

    // ⇧点击从锚点连选，锚点不动；反向也行
    selection.select("/p/d")
    selection.extend(to: "/p/b", order: order)
    #expect(selection.anchor == "/p/d" && selection.paths == ["/p/b", "/p/c", "/p/d"])
    selection.extend(to: "/p/e", order: order)
    #expect(selection.paths == ["/p/d", "/p/e"], "替换原来的范围")
    // 锚点已经不在行里（目录折叠了）：当单击
    selection.extend(to: "/p/a", order: ["/p/a", "/p/b"])
    #expect(selection.anchor == "/p/a" && selection.paths == ["/p/a"])

    // 单击回到只选一个
    selection.toggle("/p/b", order: order)
    selection.select("/p/c")
    #expect(selection.count == 1 && selection.contains("/p/c"))
}

@Test func treeSelectionRootsDropDescendantsOfSelectedDirectories() {
    let dir = FileNode(url: URL(fileURLWithPath: "/p/dir"), name: "dir", isDirectory: true)
    let inner = FileNode(url: URL(fileURLWithPath: "/p/dir/inner.txt"), name: "inner.txt", isDirectory: false)
    let sibling = FileNode(url: URL(fileURLWithPath: "/p/dir2"), name: "dir2", isDirectory: true)
    let other = FileNode(url: URL(fileURLWithPath: "/p/other.txt"), name: "other.txt", isDirectory: false)
    #expect(TreeSelection.roots([dir, inner, sibling, other]) == [dir, sibling, other])
    #expect(TreeSelection.roots([inner, other]) == [inner, other], "目录没选就不算")
}

/// 右键「复制绝对路径」：点在多选里复制整片，点在多选之外只复制这一行。
@Test func treeSelectionCopyTargetsFollowTheClickedRow() {
    let order = ["/p/a.txt", "/p/b.txt", "/p/c.txt"]
    let a = FileNode(url: URL(fileURLWithPath: "/p/a.txt"), name: "a.txt", isDirectory: false)
    let b = FileNode(url: URL(fileURLWithPath: "/p/b.txt"), name: "b.txt", isDirectory: false)
    let c = FileNode(url: URL(fileURLWithPath: "/p/c.txt"), name: "c.txt", isDirectory: false)

    var selection = TreeSelection()
    selection.select("/p/a.txt")
    selection.toggle("/p/b.txt", order: order)
    #expect(TreeSelection.targets(clicked: a, selection: selection, selected: [a, b]) == [a, b])
    #expect(TreeSelection.targets(clicked: c, selection: selection, selected: [a, b]) == [c], "点在多选之外只管这一行")

    selection.select("/p/c.txt")
    #expect(TreeSelection.targets(clicked: c, selection: selection, selected: [c]) == [c])

    #expect(TreeSelection.absolutePaths(of: [a, b]) == "/p/a.txt\n/p/b.txt", "一行一个绝对路径")
    #expect(TreeSelection.absolutePaths(of: [c]) == "/p/c.txt")
}
