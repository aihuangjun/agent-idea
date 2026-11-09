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
    let palette = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/ThemePalette.swift"), encoding: .utf8)
    let css = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/Resources/web/style.css"), encoding: .utf8)

    /// `public static let <名字> = ThemePalette(...)` 里的 `字段: 0xRRGGBB`。
    func swiftColors(_ name: String) throws -> [String: String] {
        let body = try #require(palette.firstMatch(of: try Regex("static let \(name) = ThemePalette\\((.*?)\\)\n").dotMatchesNewlines())
            .map { String($0.output[1].substring ?? "") })
        return Dictionary(uniqueKeysWithValues: body.matches(of: #/([a-zA-Z]+): 0x([0-9A-Fa-f]{6})/#)
            .map { (String($0.1), String($0.2).uppercased()) })
    }

    /// `:root { ... }` / `:root.light { ... }` 里的 `--变量: #RRGGBB;`。
    func cssColors(_ selector: String) throws -> [String: String] {
        let body = try #require(css.firstMatch(of: try Regex("\(selector) \\{(.*?)\n\\}").dotMatchesNewlines())
            .map { String($0.output[1].substring ?? "") })
        return Dictionary(uniqueKeysWithValues: body.matches(of: #/--([a-z0-9-]+): #([0-9A-Fa-f]{6});/#)
            .map { (String($0.1), String($0.2).uppercased()) })
    }

    // 外壳（SwiftUI）与正文（WebView）共用的那几个面：两边都得是同一个色值
    let shared = [("editorBackground", "bg"), ("panel", "panel"), ("border", "border"),
                  ("selection", "selection"), ("text", "text"), ("secondaryText", "text-2"), ("mutedText", "text-3")]
    for (theme, selector) in [("dark", ":root"), ("light", ":root.light")] {
        let swift = try swiftColors(theme)
        let web = try cssColors(selector)
        for (field, variable) in shared {
            #expect(swift[field] != nil, "ThemePalette.\(theme) 少了 \(field)")
            #expect(swift[field] == web[variable], "\(theme) 的 \(field) / --\(variable) 两边不一致：\(swift[field] ?? "无") vs \(web[variable] ?? "无")")
        }
    }

    // 语法色整组对上：ThemePalette 的 syntaxFooBar ↔ style.css 的 --syn-foo-bar（tree-sitter 着色新增的语义色也在里面）
    for (theme, selector) in [("dark", ":root"), ("light", ":root.light")] {
        let swift = try swiftColors(theme)
        let web = try cssColors(selector)
        let syntaxFields = swift.keys.filter { $0.hasPrefix("syntax") }
        #expect(syntaxFields.count >= 28, "ThemePalette.\(theme) 的语法色不全：\(syntaxFields.sorted())")
        for field in syntaxFields {
            let name = field.dropFirst("syntax".count)
            let variable = "syn-" + name.replacing(#/[A-Z]/#) { "-" + $0.output.lowercased() }.dropFirst()
            #expect(swift[field] == web[String(variable)], "\(theme) 的 \(field) / --\(variable) 两边不一致：\(swift[field] ?? "无") vs \(web[String(variable)] ?? "无")")
        }
    }

    // 浅色必须真的是另一套色：整块照抄深色的话这条会响
    let dark = try swiftColors("dark")
    let light = try swiftColors("light")
    #expect(dark.count == light.count, "两套调色板的字段要一一对应")
    #expect(dark["editorBackground"] != light["editorBackground"])
}

/// tree-sitter 着色的语言表（web/syntax.js 的 LANGUAGES）、vendor 目录、fetch_vendor.sh、自写查询（web/syntax/）四处一致：
/// 表里引用的语法包与查询都在、下载脚本下的就是 vendor 里有的、syntax/ 里没有没人用的查询文件；页面按顺序加载了脚本与样式。
@Test func treeSitterLanguagesAgreeAcrossFiles() throws {
    let web = packageRoot.appendingPathComponent("Sources/DesignSystem/Resources/web")
    let vendor = web.appendingPathComponent("vendor/tree-sitter")
    let syntax = try String(contentsOf: web.appendingPathComponent("syntax.js"), encoding: .utf8)
    let table = try #require(syntax.firstMatch(of: #/const LANGUAGES = \[(.*?)\n  \];/#.dotMatchesNewlines()).map { String($0.1) })
    func list(_ key: String) throws -> [String] {
        try table.matches(of: try Regex("\\b\(key): \\[([^\\]]*)\\]")).flatMap { match in
            (match.output[1].substring ?? "").matches(of: #/"([^"]+)"/#).map { String($0.1) }
        }
    }
    let grammars = Set(table.matches(of: #/grammar: "([a-z]+)"/#).map { String($0.1) })
    let highlights = Set(try list("highlights"))
    let own = Set(try list("own"))
    let locals = Set(try list("locals"))
    #expect(grammars.count >= 8, "语言表解析不出来：\(grammars)")

    let wasm = Set(try FileManager.default.contentsOfDirectory(atPath: vendor.path).filter { $0.hasPrefix("tree-sitter-") && $0.hasSuffix(".wasm") }
        .map { String($0.dropFirst("tree-sitter-".count).dropLast(".wasm".count)) })
    #expect(grammars == wasm, "语言表的语法包与 vendor 不一致：\(grammars.symmetricDifference(wasm))")
    #expect(FileManager.default.fileExists(atPath: vendor.appendingPathComponent("web-tree-sitter.wasm").path))
    #expect(FileManager.default.fileExists(atPath: vendor.appendingPathComponent("web-tree-sitter.js").path))

    var vendoredQueries: Set<String> = []
    for directory in try FileManager.default.contentsOfDirectory(atPath: vendor.appendingPathComponent("queries").path) {
        for file in try FileManager.default.contentsOfDirectory(atPath: vendor.appendingPathComponent("queries/\(directory)").path) where file.hasSuffix(".scm") {
            vendoredQueries.insert("\(directory)/\(file.dropLast(4))")
        }
    }
    #expect(highlights == vendoredQueries, "语言表引用的官方查询与 vendor 不一致：\(highlights.symmetricDifference(vendoredQueries))")

    let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/fetch_vendor.sh"), encoding: .utf8)
    let fetchedGrammars = Set(try #require(script.firstMatch(of: #/for grammar in ([^;]+); do/#)).1.split(separator: " ").map { String($0.split(separator: ":").last!) })
    #expect(fetchedGrammars == wasm, "fetch_vendor.sh 下载的语法包与 vendor 不一致：\(fetchedGrammars.symmetricDifference(wasm))")
    let fetchedQueries = Set(try #require(script.firstMatch(of: #/for query in ([^;]+); do/#)).1.split(separator: " ").map { entry -> String in
        let parts = entry.split(separator: ":")
        return "\(parts[0].split(separator: "@")[0])/\(parts[1])"
    })
    #expect(fetchedQueries == vendoredQueries, "fetch_vendor.sh 下载的查询与 vendor 不一致：\(fetchedQueries.symmetricDifference(vendoredQueries))")

    let ownFiles = Set(try FileManager.default.contentsOfDirectory(atPath: web.appendingPathComponent("syntax").path).filter { $0.hasSuffix(".scm") }.map { String($0.dropLast(4)) })
    let referenced = own.union(locals.map { $0 + "-locals" })
    #expect(referenced == ownFiles, "syntax/ 里的自写查询与语言表不一致：\(referenced.symmetricDifference(ownFiles))")

    // 页面：tree-sitter 运行时在 syntax.js 之前、syntax.js 在 render.js 之前；syntax-idea.css 也排在 cm-idea.css 之后（主要靠选择器多一级）
    let html = try String(contentsOf: web.appendingPathComponent("index.html"), encoding: .utf8)
    func position(_ needle: String) -> String.Index? { html.range(of: needle)?.lowerBound }
    let order = ["vendor/tree-sitter/web-tree-sitter.js", "\"syntax.js\"", "\"render.js\""].map(position)
    #expect(order.allSatisfy { $0 != nil } && order[0]! < order[1]! && order[1]! < order[2]!, "index.html 里脚本顺序不对")
    if let cm = position("\"cm-idea.css\""), let ts = position("\"syntax-idea.css\"") { #expect(cm < ts) } else { Issue.record("index.html 缺 syntax-idea.css") }
    // 资源协议两处手写（Swift 的 Core/WebAsset 与 syntax.js），还要在 CSP 的 connect-src 里放行
    let asset = try String(contentsOf: packageRoot.appendingPathComponent("Sources/Core/WebAsset.swift"), encoding: .utf8)
    let scheme = try #require(asset.firstMatch(of: #/static let scheme = "([a-z-]+)"/#).map { String($0.1) })
    #expect(syntax.contains("\"\(scheme)://web/\""))
    #expect(html.contains("connect-src \(scheme):;"))

    // 编辑器里的 token 选择器必须比 cm-idea.css 的两级选择器多一级（.cm-s-idea .cm-overlay.cm-ts-*），不靠加载顺序
    let css = try String(contentsOf: web.appendingPathComponent("syntax-idea.css"), encoding: .utf8)
    let editorSelectors = css.matches(of: #/\.cm-s-idea \.([a-z.-]*cm-ts-[a-z-]+)/#).map { String($0.1) }
    #expect(!editorSelectors.isEmpty && editorSelectors.allSatisfy { $0.hasPrefix("cm-overlay.cm-ts-") }, "\(editorSelectors.filter { !$0.hasPrefix("cm-overlay.") })")

    // 两处 600KB 上限（syntax.js 的 SIZE_LIMIT 与 render.js 的 HIGHLIGHT_LIMIT）必须一致
    let render = try String(contentsOf: web.appendingPathComponent("render.js"), encoding: .utf8)
    let limit = { (text: String, name: String) in text.firstMatch(of: try! Regex("const \(name) = ([0-9 *]+);")).map { String($0.output[1].substring ?? "").replacingOccurrences(of: " ", with: "") } }
    #expect(limit(syntax, "SIZE_LIMIT") != nil && limit(syntax, "SIZE_LIMIT") == limit(render, "HIGHLIGHT_LIMIT"),
            "syntax.js SIZE_LIMIT 与 render.js HIGHLIGHT_LIMIT 不一致：\(limit(syntax, "SIZE_LIMIT") ?? "无") vs \(limit(render, "HIGHLIGHT_LIMIT") ?? "无")")
}
