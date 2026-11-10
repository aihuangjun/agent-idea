import Core
import Testing

/// 「代码」菜单里的编辑器命令：哪种编辑器里能用（菜单项据此灰掉），键名不重复。
@Test func editorCommandsAreAvailableOnlyWhereTheEditorSupportsThem() {
    for command in EditorCommand.allCases {
        #expect(!command.isAvailable(in: nil), "\(command) 在没有编辑器的视图里应灰掉")
        #expect(command.isAvailable(in: .plain), "\(command) 在普通编辑器里应能用")
    }
    // diff 两侧不做代码折叠，多光标照样有
    #expect(EditorCommand.allCases.filter { $0.isAvailable(in: .diff) } == [.selectNextOccurrence, .unselectOccurrence, .singleSelection])
    #expect(EditorCommand.allCases.filter(\.needsFolding) == [.fold, .unfold, .foldAll, .unfoldAll])
}

@Test func editorCommandKeysAreDistinct() {
    let keys = EditorCommand.allCases.map(\.codeMirrorKey)
    #expect(Set(keys).count == keys.count, "\(keys)")
    #expect(EditorCommand.fold.codeMirrorKey == "Cmd--" && EditorCommand.unfoldAll.codeMirrorKey == "Shift-Cmd-=")
}
