import AppKit
import SwiftUI
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

@MainActor private final class EditorModel: ObservableObject {
    @Published var text = ""
    @Published var focused = false
    @Published var releases = 0
}

@MainActor private struct EditorHost: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PlainTextEditor(text: $model.text, placeholder: "提交信息", isFocused: $model.focused, releaseFocusRequests: model.releases)
            .frame(width: 300, height: 100)
    }
}

@MainActor private func settleEditor(_ seconds: TimeInterval = 10, until done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !done() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        await Task.yield()
    }
}

/// 提交完输入框被外面清空：它自己的撤销栈跟着清（⌘Z 才会落到「撤销提交」上），`releaseFocusRequests` 一变就交出焦点。
/// 撤销栈必须是文本框自己的，不是窗口共用的那个（清后者会把别处的撤销一起清掉）。
@Test @MainActor func externalTextChangeClearsUndoAndReleaseGivesUpFocus() async throws {
    let model = EditorModel()
    let host = NSHostingView(rootView: EditorHost(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func findTextView(_ view: NSView) -> PlaceholderTextView? {
        if let found = view as? PlaceholderTextView { return found }
        for child in view.subviews { if let found = findTextView(child) { return found } }
        return nil
    }
    await settleEditor { findTextView(host) != nil }
    let textView = try #require(findTextView(host))
    #expect(window.makeFirstResponder(textView))
    textView.insertText("提交信息", replacementRange: textView.selectedRange())
    await settleEditor { model.text == "提交信息" }
    #expect(model.text == "提交信息")
    let undoManager = try #require(textView.undoManager)
    #expect(undoManager !== window.undoManager, "文本框要有自己的撤销栈")
    // 用户正在敲：模型里的文字与文本视图一样（文字是从文本视图回写过去的），撤销栈不动
    #expect(undoManager.canUndo)
    #expect(PlainTextEditor.isEditorTextView(textView))

    model.text = ""
    await settleEditor { textView.string.isEmpty }
    #expect(textView.string.isEmpty)
    #expect(!undoManager.canUndo, "换了文字，旧的编辑撤不回去了")
    #expect(window.firstResponder === textView, "只清空不交焦点（amend 预填也会改文字）")

    model.releases += 1
    await settleEditor { window.firstResponder !== textView }
    #expect(window.firstResponder !== textView)
}
