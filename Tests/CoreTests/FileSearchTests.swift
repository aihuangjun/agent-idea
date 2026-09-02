import Core
import Foundation
import Testing
import TestSupport

private func entries(_ paths: String...) -> [FileSearchEntry] { paths.map(FileSearchEntry.init) }

@Test func searchRanksNameMatchesAboveFuzzyAndPath() {
    let index = entries(
        "Sources/App/AppModel.swift", "Sources/App/Model.swift", "docs/app-model-notes.md", "Tests/AppModelTests.swift",
        "README.md", "Sources/Core/Amdl.swift", "scripts/model/app.sh"
    )
    let names = { (query: String) in FileSearch.search(query, in: index).map(\.entry.path) }
    // 全等 > 前缀 > 包含
    #expect(names("model.swift").first == "Sources/App/Model.swift")
    #expect(names("appmodel").prefix(2).elementsEqual(["Sources/App/AppModel.swift", "Tests/AppModelTests.swift"]))
    // 子序列：amdl 命中 Amdl.swift（前缀）在前，AppModel（子序列）在后
    let fuzzy = names("amdl")
    #expect(fuzzy.first == "Sources/Core/Amdl.swift")
    #expect(fuzzy.contains("Sources/App/AppModel.swift"))
    // 名字匹配不上的退到路径
    #expect(names("scripts").contains("scripts/model/app.sh"))
    // 带斜杠按路径找
    #expect(names("model/app") == ["scripts/model/app.sh"])
    // 不分大小写；空查询没有结果
    #expect(names("README") == ["README.md"] && names("readme") == ["README.md"])
    #expect(names("   ").isEmpty)
    #expect(names("zzz").isEmpty)
}

@Test func searchReportsMatchedIndicesForHighlighting() {
    let index = entries("Sources/AppModel.swift")
    let contains = FileSearch.search("model", in: index)[0]
    #expect(contains.matchedNameIndices == [3, 4, 5, 6, 7])
    let fuzzy = FileSearch.search("amsw", in: index)[0]
    #expect(fuzzy.matchedNameIndices == [0, 3, 9, 10])
    // 只按路径命中时不标文件名
    #expect(FileSearch.search("sources", in: index)[0].matchedNameIndices.isEmpty)
    // 单词开头优先不能把后面的字符「跳没了」：s 若跳到 .swift 的 s，后面的 e 就没处落，要退回贪心匹配
    let session = entries("Sources/Workbench/Model/ProjectSession.swift")
    #expect(FileSearch.search("prjsess", in: session).first?.matchedNameIndices == [0, 1, 3, 7, 8, 9, 10])
}

@Test func indexerSkipsHiddenExcludedAndSymlinkedDirectories() async throws {
    try await withTemporaryDirectory { root in
        let fm = FileManager.default
        for directory in ["src/deep", "node_modules/pkg", ".git/objects", "linked-target"] {
            try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["src/a.swift", "src/deep/b.swift", "node_modules/pkg/index.js", ".git/objects/x", "linked-target/c.txt", "README.md", ".DS_Store", ".gitignore"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("linked-target"))

        let all = FileIndexer.index(root: root) { path, _ in path == "node_modules" }
        #expect(Set(all.map(\.path)) == ["src/a.swift", "src/deep/b.swift", "linked-target/c.txt", "README.md", ".gitignore"])
        #expect(all.first { $0.path == "src/deep/b.swift" }?.name == "b.swift")
        #expect(all.first { $0.path == "src/deep/b.swift" }?.directory == "src/deep")

        let capped = FileIndexer.index(root: root, limit: 2) { _, _ in false }
        #expect(capped.count == 2)
    }
}
