import AppKit
import Testing
@testable import DesignSystem

/// 占位符必须画在第一行真文字的原点上：光标与提示才不会错位。
@Test @MainActor func placeholderStartsWhereFirstLineStarts() throws {
    let textView = PlainTextEditor.makeTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    textView.textContainer?.containerSize = NSSize(width: 300 - PlainTextEditor.inset.width * 2, height: .greatestFiniteMagnitude)
    textView.string = "hello"
    let layoutManager = try #require(textView.layoutManager)
    let container = try #require(textView.textContainer)
    layoutManager.ensureLayout(for: container)
    let fragment = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    let origin = textView.textContainerOrigin
    let firstLine = NSPoint(x: origin.x + fragment.minX + container.lineFragmentPadding, y: origin.y + fragment.minY)
    #expect(textView.placeholderOrigin == firstLine)
    #expect(textView.placeholderOrigin == NSPoint(x: PlainTextEditor.inset.width, y: PlainTextEditor.inset.height))
}

/// 高度随内容伸缩，夹在给定范围里。
@Test @MainActor func editorHeightGrowsWithContentWithinRange() throws {
    let scrollView = PlainTextEditor.makeScrollView()
    let textView = try #require(scrollView.documentView as? PlaceholderTextView)
    let range: ClosedRange<CGFloat> = 40...90

    #expect(PlainTextEditor.fittingSize(width: 300, in: scrollView, heightRange: range)?.height == 40)

    textView.string = Array(repeating: "line", count: 12).joined(separator: "\n")
    #expect(PlainTextEditor.fittingSize(width: 300, in: scrollView, heightRange: range)?.height == 90)

    textView.string = "a\nb\nc"
    let height = try #require(PlainTextEditor.fittingSize(width: 300, in: scrollView, heightRange: range)?.height)
    #expect(height > 40 && height < 90)
}
