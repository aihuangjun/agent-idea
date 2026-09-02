import Core
import Foundation
import Testing
import TestSupport

@Test func languageDetection() {
    #expect(Language.forFile(named: "App.swift").highlightID == "swift")
    #expect(Language.forFile(named: "index.TSX").highlightID == "typescript")
    #expect(Language.forFile(named: "README.md") == .markdown)
    #expect(Language.forFile(named: "package.json") == .json)
    #expect(Language.forFile(named: "Info.plist").highlightID == "xml")
    #expect(Language.forFile(named: "Dockerfile").highlightID == "dockerfile")
    #expect(Language.forFile(named: ".gitignore").name == "Ignore")
    #expect(Language.forFile(named: ".env.local").highlightID == "ini")
    #expect(Language.forFile(named: "LICENSE") == .plainText)
    #expect(Language.forFile(named: "weird.xyz") == Language(name: "XYZ", highlightID: nil))
    #expect(Language.forFile(named: "noext") == .plainText)
}

@Test func fileCategories() {
    #expect(FileCategory.forFile(named: "a.PNG") == .image)
    #expect(FileCategory.forFile(named: "doc.pdf") == .pdf)
    #expect(FileCategory.forFile(named: "notes.md") == .markdown)
    #expect(FileCategory.forFile(named: "main.go") == .code(Language(name: "Go", highlightID: "go")))
}

@Test func textDecoding() {
    if case .text(let text, let encoding, let lines) = TextFileLoader.decode(Data("a\nb\n".utf8)) {
        #expect(text == "a\nb\n")
        #expect(encoding == "UTF-8")
        #expect(lines == 2)
    } else { Issue.record("应解出文本") }

    #expect(TextFileLoader.decode(Data()) == .text("", encoding: "UTF-8", lineCount: 0))

    var binary = Data(repeating: 0x41, count: 100)
    binary.append(0)
    #expect(TextFileLoader.decode(binary) == .binary(sizeBytes: 101))

    // GB18030 的「中文」
    let gb = Data([0xD6, 0xD0, 0xCE, 0xC4])
    if case .text(let text, let encoding, _) = TextFileLoader.decode(gb) {
        #expect(text == "中文")
        #expect(encoding == "GB18030")
    } else { Issue.record("应解出 GB18030") }

    #expect(TextFileLoader.lineCount(of: "one") == 1)
    #expect(TextFileLoader.lineCount(of: "one\ntwo") == 2)
    #expect(TextFileLoader.lineCount(of: "one\ntwo\n") == 2)
}

@Test func loadRespectsSizeLimit() throws {
    try withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: 2048).write(to: file)
        #expect(TextFileLoader.load(file, limit: 1024) == .tooLarge(sizeBytes: 2048, limit: 1024))
        if case .text = TextFileLoader.load(file) {} else { Issue.record("默认上限内应读出来") }
    }
}

@Test func directoryListingSortsFoldersFirstAndHidesGit() throws {
    try withTemporaryDirectory { directory in
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        try "".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent("a10.txt"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent("a2.txt"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let nodes = DirectoryLister.list(directory)
        #expect(nodes.map(\.name) == ["Alpha", "zeta", ".gitignore", "a2.txt", "a10.txt", "b.txt"])
        #expect(nodes[0].isDirectory && !nodes[2].isDirectory)
    }
}

@Test func flattenedTreeRowsFollowExpansion() {
    var tree = FlattenedTree()
    let root = "/p"
    let src = FileNode(url: URL(fileURLWithPath: "/p/src"), name: "src", isDirectory: true)
    let readme = FileNode(url: URL(fileURLWithPath: "/p/README.md"), name: "README.md", isDirectory: false)
    let main = FileNode(url: URL(fileURLWithPath: "/p/src/main.swift"), name: "main.swift", isDirectory: false)
    tree.setChildren([src, readme], for: root)
    #expect(tree.rows(root: root).map(\.node.name) == ["src", "README.md"])
    #expect(tree.needsLoading(root: root).isEmpty)

    tree.expand("/p/src")
    #expect(tree.needsLoading(root: root) == ["/p/src"])
    tree.setChildren([main], for: "/p/src")
    let rows = tree.rows(root: root)
    #expect(rows.map(\.node.name) == ["src", "main.swift", "README.md"])
    #expect(rows.map(\.depth) == [0, 1, 0])
    #expect(rows[0].isExpanded)

    tree.collapse("/p/src")
    #expect(tree.rows(root: root).count == 2)
    // 折叠不丢缓存；作废才丢
    #expect(tree.hasLoaded("/p/src"))
    tree.invalidate("/p/src")
    #expect(!tree.hasLoaded("/p/src"))
    #expect(tree.hasLoaded(root))
    tree.invalidate(root)
    #expect(!tree.hasLoaded(root))
}

@Test func revealExpandsAncestors() {
    var tree = FlattenedTree()
    tree.reveal("/p/a/b/c.txt", root: "/p")
    #expect(tree.isExpanded("/p/a"))
    #expect(tree.isExpanded("/p/a/b"))
    #expect(!tree.isExpanded("/p"))
    #expect(!tree.isExpanded("/p/a/b/c.txt"))
}

@Test func jsonFileStoreRoundTrips() throws {
    try withTemporaryDirectory { directory in
        let store = JSONFileStore<[RecentProject]>(url: directory.appendingPathComponent("nested/recent.json"))
        #expect(store.load() == nil)
        let value = [RecentProject(path: "/tmp/x", lastOpened: Date(timeIntervalSince1970: 100))]
        try store.save(value)
        #expect(store.load() == value)
    }
}

@Test func logFileRotates() throws {
    try withTemporaryDirectory { directory in
        let log = LogFile(directory: directory, name: "t.log", maxBytes: 64, backups: 1)
        for index in 0..<20 { log.append("line \(index) 0123456789") }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["t.log", "t.log.1"])
    }
}
