import AppKit
import Core
import DesignSystem

/// 「编辑 → 撤销 / 重做」按焦点分发（IDEA 也是按上下文撤：编辑器里撤编辑，项目视图里撤文件操作）：
/// 1. 焦点在提交信息框、搜索框这类 AppKit 文本控件里：走系统的 `undo:`（它们自己的 NSUndoManager）；
/// 2. 焦点在 WebView 里且页面有编辑器：CodeMirror 的撤销——焦点在编辑器里时 ⌘Z 已被页面自己吃掉，不会到菜单，
///    这一条只管用鼠标点菜单的情况；页面没有编辑器（只读视图）就落到 3；
/// 3. 否则撤最近一次文件操作（重命名、移动、删除、回滚）。
/// 放在视图层：模型不该为了看第一响应者去 import AppKit。
@MainActor
enum UndoDispatcher {
    static func undo(_ workbench: WorkbenchModel) { perform(workbench, redo: false) }
    static func redo(_ workbench: WorkbenchModel) { perform(workbench, redo: true) }

    private static func perform(_ workbench: WorkbenchModel, redo: Bool) {
        let responder = NSApp.keyWindow?.firstResponder
        if responder is NSText {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
            return
        }
        let fileOperation: @MainActor () -> Void = { redo ? workbench.active?.redo() : workbench.active?.undo() }
        if let view = responder as? NSView, view.isDescendant(of: workbench.renderer.webView) {
            let completion: (Bool) -> Void = { handled in
                if !handled { Task { @MainActor in fileOperation() } }
            }
            if redo { workbench.renderer.redo(completion) } else { workbench.renderer.undo(completion) }
            return
        }
        fileOperation()
    }
}
