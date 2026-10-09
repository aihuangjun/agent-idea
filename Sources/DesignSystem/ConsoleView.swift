import AppKit
import Core
import SwiftUI

/// 「运行」窗口的输出区：只读的 `NSTextView`，能选中、复制，等宽字体。
///
/// 不用 SwiftUI 的 `Text` 一行一个：几千行就卡。也不放进共用的 WebView：那是正文的，切标签就重画了。
/// 只往后追加 `ConsoleBuffer` 里新来的段；`generation` 变了（清空、掐掉开头）才整个重来。
/// 停在底部时跟着新输出往下滚，人往上翻过就不抢滚动条（照终端 / IDEA 的习惯）。
public struct ConsoleView: NSViewRepresentable {
    let buffer: ConsoleBuffer

    public static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let inset = NSSize(width: 10, height: 6)

    public init(buffer: ConsoleBuffer) { self.buffer = buffer }

    public final class Coordinator {
        var generation = -1
        var appended = 0
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView() }

    static func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = Self.font
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        Self.apply(buffer, to: scrollView, coordinator: context.coordinator)
    }

    /// 把缓冲里还没画的段接上去（测试直接调它）。
    static func apply(_ buffer: ConsoleBuffer, to scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let atBottom = Self.isScrolledToBottom(scrollView)
        if coordinator.generation != buffer.generation || coordinator.appended > buffer.segments.count {
            storage.setAttributedString(NSAttributedString())
            coordinator.generation = buffer.generation
            coordinator.appended = 0
        }
        guard coordinator.appended < buffer.segments.count else { return }
        storage.beginEditing()
        for segment in buffer.segments[coordinator.appended...] {
            storage.append(NSAttributedString(string: segment.text, attributes: Self.attributes(for: segment.kind)))
        }
        storage.endEditing()
        coordinator.appended = buffer.segments.count
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    /// 颜色用 `Theme` 的动态色：换浅色 / 深色时已经画上去的字也跟着变。
    static func attributes(for kind: ConsoleBuffer.Kind) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        switch kind {
        case .output: color = NSColor(Theme.text)
        case .error: color = NSColor(Theme.danger)
        case .system: color = NSColor(Theme.secondaryText)
        }
        return [.font: font, .foregroundColor: color]
    }

    /// 离底部差不到一行就算在底部。
    static func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= document.bounds.maxY - 20
    }
}
