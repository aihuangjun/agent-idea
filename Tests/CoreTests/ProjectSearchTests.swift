import Foundation
import Testing
import TestSupport
@testable import Core

@Test func globalSearchFiltersTypesFilesAndSymbolsWithNavigationPositions() {
    let files = ["src/WebServer.java", "README.md"].map(FileSearchEntry.init(path:))
    let type = SourceSymbol(name: "WebServer", qualifiedName: "api.WebServer", kind: .type, line: 1, ch: 13)
    let method = SourceSymbol(name: "startServer", qualifiedName: "api.WebServer.startServer", kind: .function, line: 4, ch: 8)
    let symbols = [type, method].map { ProjectSearch.IndexedSymbol(symbol: $0, path: "src/WebServer.java") }
    func search(_ query: String, _ scope: ProjectSearch.Scope) -> [ProjectSearch.Result] {
        ProjectSearch.search(query, scope: scope, files: files, symbols: symbols, root: "/tmp/project")
    }

    #expect(search("WebServer", .all).prefix(2).map(\.name) == ["WebServer", "WebServer.java"])
    #expect(search("WS", .types).map(\.symbol) == [type])
    #expect(search("api.WebServer.startServer", .symbols).first?.location == SourceLocation(line: 5, column: 9))
    #expect(search("startServer", .types).isEmpty)
    #expect(search("src/WebServer.java:23:4", .all).first?.location == SourceLocation(line: 23, column: 4))
    #expect(search("README", .files).first?.path == "README.md")
}

@Test func sameNamedFilesDisplayTheirProjectRelativePaths() {
    let paths = ["index.html", "admin/public/index.html", "web/public/index.html"]
    let files = paths.map(FileSearchEntry.init(path:))
    for scope in [ProjectSearch.Scope.all, .files] {
        let results = ProjectSearch.search("index.html", scope: scope, files: files, symbols: [], root: "/tmp/project")
        #expect(results.map(\.name) == Array(repeating: "index.html", count: 3))
        #expect(Set(results.map(\.displayPath)) == ["./index.html", "admin/public/index.html", "web/public/index.html"])
        #expect(Set(results.map(\.path)) == Set(paths), "跳转仍使用原始项目相对路径")
        for reference in ["./index.html", "`./index.html:8`", "/tmp/project/index.html", "file:///tmp/project/index.html#L8"] {
            let rooted = ProjectSearch.search(reference, scope: scope, files: files, symbols: [], root: "/tmp/project")
            #expect(rooted.map(\.path) == ["index.html"])
            if reference.contains("8") { #expect(rooted.first?.location == SourceLocation(line: 8)) }
        }
    }
}

@Test func globalSearchDoesNotUseParentDirectoryToMatchCompleteFilenames() {
    let paths = ["mcp.md", "docs/MCP.md", "mcp/wiki-raws-patterns.md", "mcp.md/wiki-raws-patterns.md", "docs/mcp.md.bak"]
    let files = paths.map(FileSearchEntry.init(path:))
    let method = SourceSymbol(name: "md", qualifiedName: "mcp.md", kind: .function, line: 0, ch: 0)
    let symbols = [ProjectSearch.IndexedSymbol(symbol: method, path: "mcp.java")]
    for scope in [ProjectSearch.Scope.all, .files] {
        let results = ProjectSearch.search("mcp.md", scope: scope, files: files, symbols: symbols, root: "/tmp/project")
        #expect(Set(results.map(\.path)) == ["mcp.md", "docs/MCP.md"])
    }
    #expect(ProjectSearch.search("mcp.md", scope: .all, files: [], symbols: symbols, root: "/tmp/project").isEmpty)
    #expect(ProjectSearch.search("mcp.md", scope: .symbols, files: files, symbols: symbols, root: "/tmp/project").map(\.symbol) == [method])
}

@Test func javaImplementationsFollowImportsAndTransitiveInheritance() throws {
    typealias Declaration = JavaSource.TypeDeclaration
    func declaration(_ name: String, _ kind: SourceSymbol.Kind = .type, owner: String? = nil, parents: [String] = []) -> Declaration {
        let symbol = SourceSymbol(name: name.components(separatedBy: ".").last!, qualifiedName: name, kind: kind, line: 0, ch: 0)
        return Declaration(symbol: symbol, owner: owner, parents: parents)
    }
    func file(_ path: String, _ pkg: String, _ imports: [String] = [], _ declarations: [Declaration]) -> SourceOutline {
        SourceOutline(path: path, symbols: declarations.map(\.symbol), java: JavaSource(package: pkg, imports: imports, types: declarations))
    }
    let outlines = [
        file("api/Service.java", "api", [], [declaration("api.Service", .interface)]),
        file("legacy/Service.java", "legacy", [], [
            declaration("legacy.Service", .interface), declaration("legacy.Different", parents: ["Service"])
        ]),
        file("spi/Channel.java", "spi", ["api.Service"], [declaration("spi.Channel", .interface, parents: ["Service"])]),
        file("impl/Base.java", "impl", ["spi.*"], [declaration("impl.Base", parents: ["Channel"])]),
        file("impl/Final.java", "impl", [], [declaration("impl.Final", parents: ["Base", "api.Service"])]),
        file("nested/Container.java", "nested", [], [
            declaration("nested.Container"), declaration("nested.Container.Service", .interface, owner: "nested.Container"),
            declaration("nested.Container.Own", owner: "nested.Container", parents: ["Service"])
        ])
    ]
    let imported = JavaTypeReference(name: "Service", package: "client", imports: ["api.Service"], owner: "client.App", declared: nil)
    let found = try #require(JavaImplementations.find(imported, in: outlines))
    #expect(found.interfaceName == "api.Service")
    #expect(found.matches.map(\.symbol.qualifiedName) == ["impl.Base", "impl.Final"])
    let nested = JavaTypeReference(name: "Service", package: "nested", imports: [], owner: "nested.Container", declared: nil)
    #expect(JavaImplementations.find(nested, in: outlines)?.matches.map(\.symbol.qualifiedName) == ["nested.Container.Own"])
    let ambiguous = JavaTypeReference(name: "Service", package: "client", imports: ["api.*", "legacy.*"], owner: nil, declared: nil)
    #expect(JavaImplementations.find(ambiguous, in: outlines) == nil)
}

@Test func sourceIndexBatchReusesVersionsAndReadsDrafts() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("Api.java")
        try "interface Api {}\n".write(to: file, atomically: true, encoding: .utf8)
        let paths = ["Api.java", "README.md"].map(FileSearchEntry.init(path:))
        let first = ProjectSourceFiles.prepare(paths, root: root, drafts: [:], cached: [:])
        #expect(first.changed.map(\.text) == ["interface Api {}\n"])
        let same = ProjectSourceFiles.prepare(paths, root: root, drafts: [:], cached: first.versions)
        #expect(same.changed.isEmpty && same.versions == first.versions)
        let draft = [file.resolvingSymlinksInPath().path: "interface Renamed {}\r\n"]
        let changed = ProjectSourceFiles.prepare(paths, root: root, drafts: draft, cached: same.versions)
        #expect(changed.changed.map(\.text) == ["interface Renamed {}\n"])
        #expect(changed.versions != same.versions)
    }
}

@Test func doubleShiftRequiresTwoUninterruptedShortPresses() {
    var detector = DoubleShiftDetector(interval: 0.4)
    func shift(_ isDown: Bool, at time: TimeInterval) -> Bool { detector.shift(isDown: isDown, at: time) }
    #expect(!shift(true, at: 1))
    #expect(!shift(false, at: 1.05))
    #expect(!shift(true, at: 1.15))
    #expect(shift(false, at: 1.20))
    #expect(!shift(true, at: 2))
    #expect(!shift(false, at: 2.06))
    detector.reset()
    #expect(!shift(true, at: 2.10))
    #expect(!shift(false, at: 2.15))
    #expect(!shift(true, at: 2.17))
    #expect(!shift(false, at: 2.75))
}
