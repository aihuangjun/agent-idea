import AppKit
import Core
import Foundation

/// 交给系统去做的几件事。放在视图层：模型不该 import AppKit 只为了调 NSWorkspace。
enum Desktop {
    static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func openWithDefaultApp(_ url: URL) { NSWorkspace.shared.open(url) }

    /// 在终端里运行一个脚本：生成 `.command` 包装文件交给系统打开，默认由终端执行（见 `TerminalLauncher`）。
    /// 失败了返回错误文案，由调用方决定显示在哪。
    @discardableResult
    static func runInTerminal(_ script: URL) -> String? {
        do {
            let wrapper = try TerminalLauncher.prepare(script: script, in: AppPaths.runDirectory)
            NSWorkspace.shared.open(wrapper)
            Log.info("terminal", "在终端中运行 \(script.path)")
            return nil
        } catch {
            Log.warn("terminal", "准备运行 \(script.path) 失败：\(error)")
            return "无法在终端中运行 \(script.lastPathComponent)：\(error.userFacingDescription)"
        }
    }
}
