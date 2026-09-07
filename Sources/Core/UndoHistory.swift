import Foundation

/// 撤销 / 重做栈（IDEA 的 Undo / Redo），纯值类型：只管「哪些操作能撤、撤了以后能不能重做」的顺序，
/// 操作本身怎么撤是调用方的事。
///
/// 用法：做完一件事 `record`；撤销时 `popUndo` 拿走栈顶，真的撤成了再 `pushRedo` 放到重做栈里，
/// 撤不成就丢掉（磁盘上的东西已经不是当时的样子了，留着它下次还是撤不成）。重做对称：`popRedo` → 成了 `pushUndo`。
/// 新的操作会把重做栈清空（和所有编辑器一样：撤销之后又做了别的，被撤掉的那些就回不来了）。
public struct UndoHistory<Entry>: Sendable where Entry: Sendable {
    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []
    /// 最多记多少步，超过的从最早的丢起。
    public let limit: Int

    public init(limit: Int = 100) {
        precondition(limit > 0)
        self.limit = limit
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var nextUndo: Entry? { undoEntries.last }
    public var nextRedo: Entry? { redoEntries.last }

    /// 做了一件新的事：进撤销栈，重做栈作废。
    public mutating func record(_ entry: Entry) {
        undoEntries.append(entry)
        redoEntries.removeAll()
        if undoEntries.count > limit { undoEntries.removeFirst(undoEntries.count - limit) }
    }

    public mutating func popUndo() -> Entry? { undoEntries.popLast() }
    public mutating func popRedo() -> Entry? { redoEntries.popLast() }

    /// 撤成了：放进重做栈。
    public mutating func pushRedo(_ entry: Entry) { redoEntries.append(entry) }

    /// 重做成了：放回撤销栈。与 `record` 不同，不清重做栈（后面可能还有几步等着重做）。
    public mutating func pushUndo(_ entry: Entry) {
        undoEntries.append(entry)
        if undoEntries.count > limit { undoEntries.removeFirst(undoEntries.count - limit) }
    }

    /// 两个栈里都不要了的（比如它们指的文件已经不在了）。
    public mutating func removeAll(where shouldRemove: (Entry) -> Bool) {
        undoEntries.removeAll(where: shouldRemove)
        redoEntries.removeAll(where: shouldRemove)
    }

    public mutating func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}
