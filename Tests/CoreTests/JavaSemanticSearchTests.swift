import Core
import Foundation
import Testing
import TestSupport

@Test func javacResolvesJavaUsagesOverloadsShadowingImplementationsAndRename() async throws {
    let registered = try await ShellCommand().run(executable: URL(fileURLWithPath: "/usr/libexec/java_home"), arguments: ["-X"])
    let installations = (try? PropertyListSerialization.propertyList(from: registered.standardOutput, format: nil)) as? [[String: Any]] ?? []
    guard installations.contains(where: { installation in
        guard let version = installation["JVMVersion"] as? String,
              let major = Int(version.prefix(while: \.isNumber)), major >= 17,
              let home = installation["JVMHomePath"] as? String else { return false }
        return FileManager.default.isExecutableFile(atPath: home + "/bin/javac")
    }) else { return }
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/DesignSystem/Resources/java/AgentIdeaJava.java")
    try await withTemporaryDirectory { root in
        let sources = [
            "Runner.java": "package sample; public interface Runner { int run(int n); }",
            "Fast.java": "package sample; public class Fast implements Runner { public int run(int n) { return n; } public int run(String n) { return 7; } }",
            "Caller.java": "package sample; class Caller { int count; int run(int n) { return n + 1; } int execute(Fast runner) { int count = 3; return runner.run(count) + runner.run(\"same\") + run(this.count); } int entry(Fast runner) { return execute(runner); } }",
            "Decoy.java": "package another; class Decoy { int run(int n) { return n; } }",
        ]
        for (path, text) in sources { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let snapshot = try await JavaSemanticSearch.snapshot(root: root, drafts: [:]) { _, _ in false }
        @Sendable func selection(_ text: String, in path: String) -> JavaSemanticSearch.Selection {
            let offset = (sources[path]! as NSString).range(of: text).location
            return .init(line: 0, ch: offset, length: text.prefix { $0.isLetter }.utf16.count)
        }
        let method = selection("run(int", in: "Fast.java")
        async let references = JavaSemanticSearch.analyze(.usages, path: "Fast.java", selection: method, in: snapshot, using: script)
        async let implementation = JavaSemanticSearch.analyze(.implementations, path: "Runner.java", selection: selection("run(int", in: "Runner.java"), in: snapshot, using: script)
        async let local = JavaSemanticSearch.analyze(.usages, path: "Caller.java", selection: selection("count =", in: "Caller.java"), in: snapshot, using: script)
        async let hierarchy = JavaSemanticSearch.analyze(.hierarchy, path: "Fast.java", selection: method, in: snapshot, using: script)
        async let rename = JavaSemanticSearch.analyze(.rename, path: "Fast.java", selection: method, in: snapshot, using: script)
        let uses = try await references
        #expect(uses.errors == 0)
        #expect(uses.hits.map(\.path) == ["Caller.java"])
        #expect(uses.hits.first?.column == (sources["Caller.java"]! as NSString).range(of: "run(count)").location)
        #expect(try await implementation.hits.map(\.title) == ["sample.Fast.run(int)"])
        let localUses = try await local
        #expect(localUses.hits.count == 1)
        let calls = try await hierarchy
        #expect(calls.edges.count == 2)
        #expect(calls.nodes.contains { $0.title.contains("entry(") })

        let renameInput = try await rename
        let preview = try await JavaSemanticSearch.prepareRename(renameInput, to: "perform", snapshot: snapshot, script: script)
        #expect(Set(preview.changes.map(\.path)) == ["Runner.java", "Fast.java", "Caller.java"])
        try FileTextTransaction.write(preview.changes, under: root)
        let caller = try String(contentsOf: root.appendingPathComponent("Caller.java"), encoding: .utf8)
        #expect(caller.contains("runner.perform(count)") && caller.contains("runner.run(\"same\")") && caller.contains("run(this.count)"))
        try FileTextTransaction.write(preview.changes, under: root, reversing: true)

        let conflict = try await JavaSemanticSearch.analyze(.rename, path: "Caller.java", selection: selection("count;", in: "Caller.java"), in: snapshot, using: script)
        await #expect(throws: TextSearchError.self) {
            _ = try await JavaSemanticSearch.prepareRename(conflict, to: "class", snapshot: snapshot, script: script)
        }

        let type = try await JavaSemanticSearch.analyze(.rename, path: "Fast.java", selection: selection("Fast implements", in: "Fast.java"), in: snapshot, using: script)
        let renamed = try await JavaSemanticSearch.prepareRename(type, to: "Preferred", snapshot: snapshot, script: script)
        #expect(renamed.changes.first { $0.path == "Fast.java" }?.newPath == "Preferred.java")
        try FileTextTransaction.write(renamed.changes, under: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Fast.java").path))
        #expect(try String(contentsOf: root.appendingPathComponent("Caller.java"), encoding: .utf8).contains("Preferred runner"))
        try FileTextTransaction.write(renamed.changes, under: root, reversing: true)
    }
}
