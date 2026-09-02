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
    #expect(script.contains("RELEASES=\"releases\""))
    #expect(swift.contains("releasesDirectory = \"releases\""))
    #expect(script.contains("latest.json") && swift.contains("manifestName = \"latest.json\""))
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

@Test func themeAndStylesheetShareColors() throws {
    let theme = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/Theme.swift"), encoding: .utf8)
    let css = try String(contentsOf: packageRoot.appendingPathComponent("Sources/DesignSystem/Resources/web/style.css"), encoding: .utf8)
    for (swiftHex, cssHex) in [("0x1E1F22", "#1E1F22"), ("0x2B2D30", "#2B2D30"), ("0x393B40", "#393B40"), ("0x2E436E", "#2E436E"), ("0xDFE1E5", "#DFE1E5")] {
        #expect(theme.contains(swiftHex) && css.contains(cssHex), "主题色 \(cssHex) 两边不一致")
    }
}
