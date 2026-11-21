import Core
import Foundation
import Testing
import TestSupport

@Test func definitionSearchPrefersDraftsAndStaysInsideProject() async throws {
    try await withTemporaryDirectory { directory in
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func file(_ name: String, _ content: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let use = try file("Use.java", "class Use { Target target; }")
        let draft = try file("Draft.java", "class Draft {}")
        _ = try file("Stale.java", "class Target {}")
        _ = try file("Ignored.java", "class Target {}")
        _ = try file("Other.swift", "struct Target {}")
        let outside = directory.appendingPathComponent("Outside.java")
        try "class Target {}".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.java"), withDestinationURL: outside)
        let input = try await DefinitionSearch.input(
            name: "Target", source: use, root: root, git: nil,
            drafts: [draft.path: "class Target {\r\n}\r\n", root.appendingPathComponent("Stale.java").path: "class Renamed {}"]
        ) { path, _ in path == "Ignored.java" }
        #expect(input.sources.map(\.path) == [draft.path])
        #expect(input.sources.first?.text == "class Target {\n}\n")
        #expect(!input.truncated)
    }
}
