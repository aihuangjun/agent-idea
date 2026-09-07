import Core
import Foundation
import Testing

@Test func undoHistoryOrdersUndoAndRedo() {
    var history = UndoHistory<String>(limit: 3)
    #expect(!history.canUndo && !history.canRedo)
    history.record("a")
    history.record("b")
    #expect(history.nextUndo == "b")

    // 撤销：拿走栈顶，成了才进重做栈
    let undone = history.popUndo()
    #expect(undone == "b" && history.nextUndo == "a" && !history.canRedo)
    history.pushRedo("b")
    #expect(history.canRedo && history.nextRedo == "b")

    // 重做：放回撤销栈，重做栈里剩下的留着
    history.pushRedo("z")
    let redone = history.popRedo()
    #expect(redone == "z")
    history.pushUndo("z")
    #expect(history.undoEntries == ["a", "z"] && history.redoEntries == ["b"], "重做不清重做栈")

    // 新操作把重做栈清空
    history.record("c")
    #expect(history.redoEntries.isEmpty)
    #expect(history.undoEntries == ["a", "z", "c"])

    // 超过上限从最早的丢起
    history.record("d")
    #expect(history.undoEntries == ["z", "c", "d"])
    history.pushUndo("e")
    #expect(history.undoEntries == ["c", "d", "e"])

    history.pushRedo("d")
    history.removeAll { $0 == "d" }
    #expect(history.undoEntries == ["c", "e"] && history.redoEntries.isEmpty)
    history.clear()
    #expect(!history.canUndo && !history.canRedo)
}
