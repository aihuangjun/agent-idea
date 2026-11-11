import Core
import Foundation
import Testing
import TestSupport

@Test func htmlPreviewKeepsDoctypeAndOriginalResourceBase() {
    let file = URL(fileURLWithPath: "/project/web/page.html")
    let html = "<!doctype html><html><head><title>Title</title></head><body>正文</body></html>"
    let rendered = HTMLPreviewDocument.resolvingResources(in: html, relativeTo: file)
    #expect(rendered == "<!doctype html><html><head><base href=\"file:///project/web/page.html\"><title>Title</title></head><body>正文</body></html>")
    #expect(HTMLPreviewDocument.resolvingResources(in: "<!doctype html><h1>Hi</h1>", relativeTo: file).hasPrefix("<!doctype html><base "))
    #expect(HTMLPreviewDocument.resolvingResources(in: "<h1>Hi</h1>", relativeTo: file).hasPrefix("<base "))
}

@Test func htmlPreviewResolvesExplicitBaseAndIgnoresScriptExamples() {
    let file = URL(fileURLWithPath: "/project/web/page.html")
    let html = "<HEAD><!-- <base href='wrong/'> --><script>const demo = '<base href=\"wrong\">';</script><BASE target='_blank' HREF='../assets/'></HEAD>"
    let rendered = HTMLPreviewDocument.resolvingResources(in: html, relativeTo: file)
    #expect(rendered.contains("<BASE target='_blank' href=\"file:///project/assets/\">"))
    #expect(rendered.contains("const demo = '<base href=\"wrong\">'"))
    #expect(HTMLPreviewDocument.resolvingResources(in: "<base href=https://example.com/assets/>", relativeTo: file) == "<base href=\"https://example.com/assets/\">")
}

@Test func gitMetadataPathsResolveRelativeAndWorktreeDirectories() async {
    let runner = FakeCommandRunner { arguments, _ in
        shellOutput(arguments.contains("--absolute-git-dir") ? "/repo/.git/worktrees/feature\n" : "../.git\n")
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let paths = await git.metadataDirectories(repositoryRoot: URL(fileURLWithPath: "/repo/feature", isDirectory: true))
    #expect(paths.map(\.path) == ["/repo/.git/worktrees/feature", "/repo/.git"])
}

@Test func htmlPreviewResourceScopeRejectsEscapesAndSymbolicLinks() async throws {
    try await withTemporaryDirectory { directory in
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let nested = project.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside.js")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape.js"), withDestinationURL: outside)
        let file = nested.appendingPathComponent("中文 page.html")
        let resource = try #require(HTMLPreviewDocument.resourceURL(for: file, within: project))
        #expect(resource.path == "/web/中文 page.html")
        #expect(!resource.absoluteString.contains(project.path))
        #expect(HTMLPreviewDocument.fileURL(for: resource, within: project)?.path == file.resolvingSymlinksInPath().path)
        #expect(HTMLPreviewDocument.resourceDirectory(for: file, in: project) == project)
        #expect(HTMLPreviewDocument.resourceDirectory(for: outside, in: project) == directory)
        #expect(HTMLPreviewDocument.resourceURL(for: outside, within: project) == nil)
        #expect(HTMLPreviewDocument.resourceURL(for: project.appendingPathComponent("../outside.js"), within: project) == nil)
        #expect(HTMLPreviewDocument.fileURL(for: URL(string: "agentidea-html://preview/escape.js")!, within: project) == nil)
        #expect(HTMLPreviewDocument.fileURL(for: URL(string: "agentidea-html://preview/%2e%2e/outside.js")!, within: project) == nil)
        #expect(HTMLPreviewDocument.fileURL(for: outside, within: project) == nil)
        #expect(HTMLPreviewDocument.fileURL(for: URL(string: "agentidea-html://other" + resource.path)!, within: project) == nil)
    }
}

@Test func htmlPreviewUsesProjectRootAndDirectoryIndexes() async throws {
    try await withTemporaryDirectory { project in
        let pages = project.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        let page = pages.appendingPathComponent("中文 #?.html")
        try "page".write(to: page, atomically: true, encoding: .utf8)
        let resource = try #require(HTMLPreviewDocument.resourceURL(for: page, within: project))
        let rootAsset = try #require(URL(string: "/assets/style.css?v=2#color", relativeTo: resource)?.absoluteURL)
        let relativeAsset = try #require(URL(string: "../assets/style.css", relativeTo: resource)?.absoluteURL)
        let expected = project.appendingPathComponent("assets/style.css").resolvingSymlinksInPath()
        #expect(HTMLPreviewDocument.fileURL(for: resource, within: project) == page.resolvingSymlinksInPath())
        #expect(HTMLPreviewDocument.fileURL(for: rootAsset, within: project) == expected)
        #expect(HTMLPreviewDocument.fileURL(for: relativeAsset, within: project) == expected)
        let folder = try #require(URL(string: "/pages/", relativeTo: resource)?.absoluteURL)
        #expect(HTMLPreviewDocument.fileURL(for: folder, within: project) == pages.appendingPathComponent("index.html").resolvingSymlinksInPath())
        for address in ["agentidea-html://other/a", "agentidea-html://user@preview/a", "agentidea-html://preview:80/a", "file:///etc/passwd"] {
            #expect(HTMLPreviewDocument.fileURL(for: URL(string: address)!, within: project) == nil)
        }
        // 目录的默认首页也必须校验符号链接，不能绕过读取范围。
        let outside = project.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).html")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: pages.appendingPathComponent("index.html"), withDestinationURL: outside)
        #expect(HTMLPreviewDocument.fileURL(for: folder, within: project) == nil)
    }
}

@Test func htmlPreviewBaseIgnoresRawTextAndQuotedTagDelimiters() {
    let file = URL(fileURLWithPath: "/project/page.html")
    let html = "<head data-example='>'><style>p::after {content: '<base href=wrong>'}</style><title>&lt;head&gt;</title></head><textarea><base href='wrong'></textarea>"
    let result = HTMLPreviewDocument.resolvingResources(in: html, relativeTo: file)
    #expect(result.hasPrefix("<head data-example='>'><base href=\"file:///project/page.html\">"))
    #expect(result.contains("content: '<base href=wrong>'"))
    #expect(result.contains("<textarea><base href='wrong'></textarea>"))
    #expect(HTMLPreviewDocument.resolvingResources(in: "<base data-href='wrong' data-example=\" href='also-wrong'\" href='assets/'>", relativeTo: file)
        == "<base data-href='wrong' data-example=\" href='also-wrong'\" href=\"file:///project/assets/\">")
}

@Test func gitMetadataEventsMatchRealPathsAndSymbolicAliases() async throws {
    try await withTemporaryDirectory { directory in
        let metadata = directory.appendingPathComponent("metadata", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: metadata)
        let actual = metadata.resolvingSymlinksInPath().path
        let physical = actual.hasPrefix("/var/") || actual.hasPrefix("/tmp/") ? "/private" + actual : actual
        let direct = GitMetadataEventFilter(directory: metadata)
        let linked = GitMetadataEventFilter(directory: alias)
        #expect(direct.isRelevant(physical + "/index"))
        #expect(linked.isRelevant(physical + "/HEAD"))
        #expect(linked.isRelevant(physical + "/refs/heads/main"))
        #expect(linked.isRelevant(physical))
        #expect(linked.isRelevant(alias.path + "/index"))
        #expect(!linked.isRelevant(physical + "/index.lock"))
        #expect(!linked.isRelevant(physical + "/objects/a/b"))
        #expect(!linked.isRelevant(physical + "-other/index"))
    }
}
