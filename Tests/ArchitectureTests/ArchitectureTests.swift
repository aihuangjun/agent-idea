import Foundation
import Testing

/// 分层规矩由这里守着：读源文件本身，断言哪些 import 不许出现。
private let packageRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
    return url.deletingLastPathComponent()
}()

private func swiftFiles(under relative: String) throws -> [URL] {
    let directory = packageRoot.appendingPathComponent(relative)
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func imports(in file: URL) throws -> Set<String> {
    let text = try String(contentsOf: file, encoding: .utf8)
    var result: Set<String> = []
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("import ") else { continue }
        let tokens = trimmed.split(separator: " ").map(String.init)
        if let index = tokens.firstIndex(of: "import"), index + 1 < tokens.count {
            result.insert(tokens[index + 1])
        }
    }
    return result
}

@Test func coreHasNoUIDependencies() throws {
    let files = try swiftFiles(under: "Sources/Core")
    #expect(!files.isEmpty)
    for file in files {
        let found = try imports(in: file)
        for banned in ["SwiftUI", "AppKit", "WebKit", "DesignSystem", "Workbench"] {
            #expect(!found.contains(banned), "\(file.lastPathComponent) 不该 import \(banned)")
        }
    }
}

@Test func designSystemDoesNotKnowTheWorkbench() throws {
    for file in try swiftFiles(under: "Sources/DesignSystem") {
        #expect(!(try imports(in: file)).contains("Workbench"), "\(file.lastPathComponent) 不该 import Workbench")
    }
}

@Test func executableTargetIsJustAShell() throws {
    let files = try swiftFiles(under: "Sources/AgentIDEAApp")
    #expect(files.count == 1)
    let text = try String(contentsOf: files[0], encoding: .utf8)
    #expect(text.contains("@main"))
    // 代码行数（不含注释与空行）不许超过 15：executable target 测不了，逻辑一行都不许放
    let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    #expect(code.count <= 15)
}

@Test func noModalDialogsOutsideThePicker() throws {
    // runModal 会让整套测试挂住。只允许 WorkbenchView 里选目录那一处。
    for file in try swiftFiles(under: "Sources") where file.lastPathComponent != "WorkbenchView.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("runModal()"), "\(file.lastPathComponent) 里有 runModal")
    }
}

@Test func distributionConstantsAgreeWithReleaseScript() throws {
    let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
    let swift = try String(contentsOf: packageRoot.appendingPathComponent("Sources/Core/AppDistribution.swift"), encoding: .utf8)
    // tag 前缀：脚本打 tag、应用解析 tag 用的必须是同一个
    #expect(script.contains("TAG=\"v$VERSION\"") && swift.contains("tagPrefix = \"v\""))
    #expect(script.contains("gh release create \"$TAG\"") && swift.contains("/releases/latest"))
    // 构建脚本写的 Info.plist 键与 BuildIdentity 读的必须一致
    let build = try String(contentsOf: packageRoot.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
    let identity = try String(contentsOf: packageRoot.appendingPathComponent("Sources/Core/BuildIdentity.swift"), encoding: .utf8)
    for key in ["AIBuildTimestamp", "AIBuildChannel"] {
        #expect(build.contains("<key>\(key)</key>") && identity.contains("\"\(key)\""))
    }
    let web = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/WebResources.swift"), encoding: .utf8)
    #expect(build.contains("AgentIDEA_DesignSystem.bundle") && web.contains("\"AgentIDEA_DesignSystem.bundle\""))
    // 签名身份名三处必须一致；更新器换装时找的 app 名要和 release.sh 装进 dmg 的一致
    let signing = try String(contentsOf: packageRoot.appendingPathComponent("scripts/make_signing_identity.sh"), encoding: .utf8)
    for text in [build, script, signing] { #expect(text.contains("\"AgentIDEA Local\"")) }
    let updater = try String(contentsOf: packageRoot.appendingPathComponent("Sources/Workbench/Shell/Updater.swift"), encoding: .utf8)
    #expect(updater.contains("/AgentIDEA.app\"") && script.contains(".build/AgentIDEA.app \"$STAGE/\""))
}

/// CodeMirror 的 mode 列表有三份手抄（index.html 的 <script>、vendor 目录、fetch_vendor.sh），必须一致；
/// Core 的语言表里每个 highlight.js 语言名要么在 render.js 的 CM_MODES 里、要么明确列在「按纯文本编辑」的名单里。
@Test func codeMirrorModesAgreeAcrossFiles() throws {
    let web = packageRoot.appendingPathComponent("Sources/DesignSystem/Resources/web")
    let html = try String(contentsOf: web.appendingPathComponent("index.html"), encoding: .utf8)
    let referenced = Set(html.matches(of: #/vendor\/codemirror\/mode\/([a-z]+)\.js/#).map { String($0.1) })
    let vendored = Set(try FileManager.default.contentsOfDirectory(atPath: web.appendingPathComponent("vendor/codemirror/mode").path)
        .filter { $0.hasSuffix(".js") }.map { String($0.dropLast(3)) })
    #expect(referenced == vendored, "index.html 引用的 mode 与 vendor 目录里的不一致：\(referenced.symmetricDifference(vendored))")
    let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/fetch_vendor.sh"), encoding: .utf8)
    let fetched = script.firstMatch(of: #/for mode in ([a-z ]+); do/#).map { Set($0.1.split(separator: " ").map(String.init)) } ?? []
    #expect(fetched == vendored, "fetch_vendor.sh 的 mode 列表与 vendor 目录不一致：\(fetched.symmetricDifference(vendored))")

    let render = try String(contentsOf: web.appendingPathComponent("render.js"), encoding: .utf8)
    let modesBlock = try #require(render.firstMatch(of: #/const CM_MODES = \{(.*?)\};/#.dotMatchesNewlines()).map { String($0.1) })
    let cmLanguages = Set(modesBlock.matches(of: #/(?:^|[\s{,])([a-z]+):/#).map { String($0.1) })
    let language = try String(contentsOf: packageRoot.appendingPathComponent("Sources/Core/Language.swift"), encoding: .utf8)
    let highlightIDs = Set(language.matches(of: #/add\(\[[^\]]*\], "[^"]*", "([^"]+)"\)/#).map { String($0.1) }
        + language.matches(of: #/highlightID: "([^"]+)"/#).map { String($0.1) })
    // 这些语言 CodeMirror 5 没有现成的 mode（或不值得多带一个文件），按纯文本编辑
    let plainTextEdited: Set<String> = ["makefile", "graphql", "vbnet", "wasm", "nix", "elixir", "erlang", "haskell", "clojure", "zig"]
    let unmapped = highlightIDs.subtracting(cmLanguages).subtracting(plainTextEdited)
    #expect(unmapped.isEmpty, "这些语言既没有 CodeMirror mode 也没登记为纯文本编辑：\(unmapped.sorted())")
    #expect(plainTextEdited.isDisjoint(with: cmLanguages), "已经有 mode 的语言不该还在纯文本名单里")
}

@Test func themeAndStylesheetShareColors() throws {
    let theme = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/Theme.swift"), encoding: .utf8)
    let css = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/Resources/web/style.css"), encoding: .utf8)
    for (swiftHex, cssHex) in [("0x1E1F22", "#1E1F22"), ("0x2B2D30", "#2B2D30"), ("0x393B40", "#393B40"), ("0x2E436E", "#2E436E"), ("0xDFE1E5", "#DFE1E5")] {
        #expect(theme.contains(swiftHex) && css.contains(cssHex), "主题色 \(cssHex) 两边不一致")
    }
}
