import AppKit
import Core
import Testing
@testable import DesignSystem

/// 控制台只往后接新来的段；换代（清空 / 掐头）才整个重画；停在底部时跟着滚，往上翻过就不动。
@Test @MainActor func consoleAppendsNewSegmentsAndFollowsTheBottom() throws {
    let scrollView = ConsoleView.makeScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
    let textView = try #require(scrollView.documentView as? NSTextView)
    let coordinator = ConsoleView.Coordinator()
    #expect(!textView.isEditable && textView.isSelectable, "只读，但能选中复制")

    var buffer = ConsoleBuffer()
    buffer.append("$ python3 a.py\n", kind: .system)
    ConsoleView.apply(buffer, to: scrollView, coordinator: coordinator)
    #expect(textView.string == "$ python3 a.py\n")

    // 只追加：已经画上去的那段对象不换（改个属性做记号，追加后还在）
    textView.textStorage?.addAttribute(.toolTip, value: "mark", range: NSRange(location: 0, length: 1))
    for index in 0..<200 { buffer.append("line \(index)\n", kind: index.isMultiple(of: 50) ? .error : .output) }
    ConsoleView.apply(buffer, to: scrollView, coordinator: coordinator)
    #expect(textView.string.hasSuffix("line 199\n"))
    #expect(textView.textStorage?.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == "mark", "追加不该重画已有的内容")
    // 标准错误用另一种颜色
    let errorAt = (textView.string as NSString).range(of: "line 50").location
    let outputAt = (textView.string as NSString).range(of: "line 51").location
    let errorColor = textView.textStorage?.attribute(.foregroundColor, at: errorAt, effectiveRange: nil) as? NSColor
    let outputColor = textView.textStorage?.attribute(.foregroundColor, at: outputAt, effectiveRange: nil) as? NSColor
    #expect(errorColor != nil && errorColor != outputColor)

    // 一开始就在底部：跟着滚到了最后
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    #expect(ConsoleView.isScrolledToBottom(scrollView))

    // 往上翻到顶：新输出来了也不抢滚动条
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    buffer.append("late\n", kind: .output)
    ConsoleView.apply(buffer, to: scrollView, coordinator: coordinator)
    #expect(scrollView.contentView.bounds.minY == 0)
    #expect(textView.string.hasSuffix("late\n"))

    // 清空：换代，整个重来
    buffer.clear()
    buffer.append("again\n", kind: .output)
    ConsoleView.apply(buffer, to: scrollView, coordinator: coordinator)
    #expect(textView.string == "again\n")
}
