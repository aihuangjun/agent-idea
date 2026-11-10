/// 当前正文里是哪一种 CodeMirror 编辑器（render.js 决定怎么画，`RenderPayload.Content.editorKind` 照同一套规则推出来）。
public enum EditorKind: Sendable, Equatable {
    /// 普通编辑器：可编辑的代码、Markdown 源码 / 分栏（`mountEditor`），有代码折叠。
    case plain
    /// 全文 diff 的编辑器（可编辑的工作区 diff，或只读的版本对比）：没有代码折叠（上下文折叠与两侧对齐会打架），多光标照样有。
    case diff
}

/// 编辑器里的专有键盘命令：render.js 的 `extraKeys` 里绑的键，菜单栏「代码」菜单里也有一项。
///
/// **规矩：每个快捷键都要有一个能让新用户发现它的入口**（菜单项、带提示的按钮、右键菜单）。页面里再加专有键位时，
/// 在这里加一项、在「代码」菜单里挂上，`render.js` 的 `EDITOR_COMMANDS` 跟着加——`editorShortcutsAllHaveMenuEntries` 核对三处一致。
/// `rawValue` 就是 `window.ide.editorCommand(name)` 的名字。
public enum EditorCommand: String, CaseIterable, Sendable {
    /// ⌘-：折起包住光标的最里层区块（IDEA 的 Collapse）。
    case fold
    /// ⌘=：展开光标那一行上折起的区块（IDEA 的 Expand）。
    case unfold
    /// ⇧⌘-：全部折叠。
    case foldAll
    /// ⇧⌘=：全部展开。
    case unfoldAll
    /// ⌃G：选中下一处相同的文字（IDEA 的 Add Selection for Next Occurrence）。
    case selectNextOccurrence
    /// ⇧⌃G：撤掉最后加的那一处（IDEA 的 Unselect Occurrence）。
    case unselectOccurrence
    /// Esc：多光标回到单个光标（CodeMirror 自带的键位）。
    case singleSelection

    /// CodeMirror 的键名（`extraKeys` 的键）。`singleSelection` 是 CodeMirror 默认键位里的 Esc，不在 extraKeys 里。
    public var codeMirrorKey: String {
        switch self {
        case .fold: return "Cmd--"
        case .unfold: return "Cmd-="
        case .foldAll: return "Shift-Cmd--"
        case .unfoldAll: return "Shift-Cmd-="
        case .selectNextOccurrence: return "Ctrl-G"
        case .unselectOccurrence: return "Shift-Ctrl-G"
        case .singleSelection: return "Esc"
        }
    }

    /// 只有普通编辑器才有（diff 两侧不做代码折叠）。
    public var needsFolding: Bool {
        switch self {
        case .fold, .unfold, .foldAll, .unfoldAll: return true
        case .selectNextOccurrence, .unselectOccurrence, .singleSelection: return false
        }
    }

    /// 在这种编辑器里能不能用；没有编辑器（只读视图、预览、图片）时一律不能，菜单项灰掉。
    public func isAvailable(in editor: EditorKind?) -> Bool {
        guard let editor else { return false }
        return !needsFolding || editor == .plain
    }
}
