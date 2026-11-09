import Core
import Foundation
import Testing

/// 渲染页按需取 WASM / 查询的协议只放行 web 目录里白名单的文件。
@Test func webAssetResolvesOnlyWhitelistedFilesInsideTheWebDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("webasset-\(UUID().uuidString)")
    let web = root.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: web.appendingPathComponent("vendor/tree-sitter"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("wasm".utf8).write(to: web.appendingPathComponent("vendor/tree-sitter/tree-sitter-java.wasm"))
    try Data("(identifier) @x".utf8).write(to: web.appendingPathComponent("syntax.scm"))
    try Data("secret".utf8).write(to: root.appendingPathComponent("secret.wasm"))
    try Data("js".utf8).write(to: web.appendingPathComponent("render.js"))
    try FileManager.default.createSymbolicLink(at: web.appendingPathComponent("escape.wasm"), withDestinationURL: root.appendingPathComponent("secret.wasm"))

    func resolve(_ string: String) -> URL? { WebAsset.fileURL(for: URL(string: string)!, within: web) }
    #expect(resolve("agentidea-asset://web/vendor/tree-sitter/tree-sitter-java.wasm")?.lastPathComponent == "tree-sitter-java.wasm")
    #expect(resolve("agentidea-asset://web/syntax.scm") != nil)
    #expect(resolve("agentidea-asset://web/../secret.wasm") == nil, "不能用 .. 跑出 web 目录")
    #expect(resolve("agentidea-asset://web/vendor/../../secret.wasm") == nil)
    #expect(resolve("agentidea-asset://web/escape.wasm") == nil, "符号链接指到目录外也不行")
    #expect(resolve("agentidea-asset://web/render.js") == nil, "只放行 wasm 与 scm")
    #expect(resolve("agentidea-asset://other/syntax.scm") == nil, "主机必须是 web")
    #expect(resolve("agentidea-html://web/syntax.scm") == nil, "协议不对")
    #expect(resolve("agentidea-asset://web/") == nil)

    #expect(WebAsset.mimeType(for: URL(fileURLWithPath: "/a/b.wasm")) == "application/wasm")
    #expect(WebAsset.mimeType(for: URL(fileURLWithPath: "/a/b.scm")).hasPrefix("text/plain"))
}
