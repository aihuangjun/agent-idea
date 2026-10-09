import AppKit
import Core
import Foundation

/// 交给系统去做的几件事。放在视图层：模型不该 import AppKit 只为了调 NSWorkspace。
enum Desktop {
    static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func openWithDefaultApp(_ url: URL) { NSWorkspace.shared.open(url) }

    /// 往剪贴板里放一段纯文本（复制路径用）。多条路径由调用方用换行拼好——
    /// 访达、终端、编辑器都按行读。
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 在终端里运行一个脚本：生成 `.command` 包装文件交给系统打开，默认由终端执行（见 `TerminalLauncher`）。
    /// 命令与「运行」窗口是同一条（`ScriptRunner`），给要交互（`input()`、`read`）的脚本用——运行窗口的 stdin 是空的。
    /// 读的是磁盘上的内容，调用方先 `saveAll`。失败了返回错误文案，由调用方决定显示在哪。
    @discardableResult
    static func runInTerminal(_ script: URL) -> String? {
        do {
            let source = String(decoding: try Data(contentsOf: script), as: UTF8.self)
            let resolution = ScriptRunner.resolve(script: script, source: source,
                                                  isExecutable: FileManager.default.isExecutableFile(atPath: script.path),
                                                  environment: LoginShellEnvironment.current)
            guard case .ready(let command) = resolution else {
                if case .missing(_, let message) = resolution { return message }
                return nil
            }
            let wrapper = try TerminalLauncher.prepare(command: command, for: script, in: AppPaths.runDirectory)
            NSWorkspace.shared.open(wrapper)
            Log.info("terminal", "在终端中运行 \(script.path)：\(command.display)")
            return nil
        } catch {
            Log.warn("terminal", "准备运行 \(script.path) 失败：\(error)")
            return "无法在终端中运行 \(script.lastPathComponent)：\(error.userFacingDescription)"
        }
    }
}
