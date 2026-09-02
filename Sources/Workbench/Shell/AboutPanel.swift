import AppKit
import Core

/// 「关于 Agent IDEA」面板。用系统标准面板：版本那一行的排版由系统给出，与菜单里那条构建标识一致。
enum AboutPanel {
    static let applicationName = "Agent IDEA"
    static let summary = "Agent 开发配套的 IDEA"
    static let author = "shengxia.hj"

    @MainActor
    static func show(build: BuildIdentity) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: applicationName,
            .applicationVersion: build.version,
            .version: build.buildSuffix,
            .credits: credits(),
        ])
    }

    private static func credits() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 2
        return NSAttributedString(string: "\(summary)\n\(author)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }
}
