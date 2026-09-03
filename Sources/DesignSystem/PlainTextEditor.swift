import AppKit
import SwiftUI

/// 多行纯文本输入框（提交信息用）：直接包一层 `NSTextView`，占位符由文本视图自己画在第一行文字的位置上。
///
/// 不用 SwiftUI 的 `TextEditor`：它的文字有一圈拿不到的内边距，占位符只能另叠一个 `Text` 去猜位置，
/// 猜不准就是「光标比提示高一截」。这里内边距自己定，占位符与第一行文字用同一套排版从同一个原点起笔，
/// 对齐是构造出来的，不是调出来的（`PlainTextEditorTests` 核对这一点）。
///
/// 高度按内容在 `heightRange` 里伸缩，超过上限出滚动条。
public struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let heightRange: ClosedRange<CGFloat>

    /// 文字离边框的距离。
    public static let inset = NSSize(width: 8, height: 7)
    static let font = NSFont.systemFont(ofSize: 13)

    public init(text: Binding<String>, placeholder: String, isFocused: Binding<Bool>, heightRange: ClosedRange<CGFloat> = 64...120) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.heightRange = heightRange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView()
        if let textView = scrollView.documentView as? PlaceholderTextView {
            textView.delegate = context.coordinator
            textView.placeholder = placeholder
            textView.string = text
            textView.onFocusChange = { [coordinator = context.coordinator] focused in
                // 焦点变化来自 AppKit 的响应链，不在 SwiftUI 的更新回合里；挪到下一轮再写状态最稳妥
                DispatchQueue.main.async { coordinator.parent.isFocused = focused }
            }
        }
        return scrollView
    }

    /// 滚动视图 + 文本视图的骨架（不带代理与回调，测试直接拿它量尺寸）。
    static func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = makeTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        textView.placeholder = placeholder
        // 外面把文字改了（比如提交完清空）才写回去；用户正在敲的时候两边本来就一样，别打断输入法
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
    }

    /// 按内容量高度：在 `heightRange` 里随行数伸缩。
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return Self.fittingSize(width: width, in: scrollView, heightRange: heightRange)
    }

    static func fittingSize(width: CGFloat, in scrollView: NSScrollView, heightRange: ClosedRange<CGFloat>) -> CGSize? {
        guard let textView = scrollView.documentView as? PlaceholderTextView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        // 先把滚动视图摆到目标宽度（SwiftUI 随后也会摆成这个宽），文本视图与容器的宽度跟着它走（autoresizing +
        // widthTracksTextView），再量文字有多高。直接改文本视图的 frame 不行：clip view 会把它拉回自己的宽度。
        if scrollView.frame.width != width {
            scrollView.setFrameSize(NSSize(width: width, height: scrollView.frame.height))
        }
        let textWidth = max(1, scrollView.contentSize.width)
        if textView.frame.width != textWidth {
            textView.setFrameSize(NSSize(width: textWidth, height: textView.frame.height))
        }
        layoutManager.ensureLayout(for: container)
        let textHeight = ceil(layoutManager.usedRect(for: container).height) + inset.height * 2
        return CGSize(width: width, height: min(heightRange.upperBound, max(heightRange.lowerBound, textHeight)))
    }

    /// 显式搭 TextKit 1 的一套（storage → layoutManager → container → view）：量高度、画占位符都要 `layoutManager`，
    /// 系统默认给的 TextKit 2 视图一碰 `layoutManager` 就会切回兼容模式，不如一开始就说清楚。
    static func makeTextView() -> PlaceholderTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = PlaceholderTextView(frame: .zero, textContainer: container)
        textView.textContainerInset = inset
        textView.font = font
        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.text)
        textView.placeholderColor = NSColor(Theme.mutedText)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Theme.selection)]
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindPanel = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        return textView
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor

        init(parent: PlainTextEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// 会画占位符的 `NSTextView`。
///
/// 占位符不是叠上去的另一个视图，而是用一套独立的 layoutManager、同样的字体与排版行为，
/// 画在第一行文字会出现的那个原点（`placeholderOrigin`）上——基线、行高都与真文字一致，光标正好落在它前面。
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var placeholderColor = NSColor.placeholderTextColor
    /// 成为 / 不再是第一响应者。
    var onFocusChange: ((Bool) -> Void)?

    private let placeholderStorage = NSTextStorage()
    private lazy var placeholderLayout: (NSLayoutManager, NSTextContainer) = {
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        placeholderStorage.addLayoutManager(layoutManager)
        return (layoutManager, container)
    }()

    /// 占位符起笔点 = 第一行文字的原点：容器原点加上行片段内边距。
    var placeholderOrigin: NSPoint {
        NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let (layoutManager, container) = placeholderLayout
        layoutManager.typesetterBehavior = self.layoutManager?.typesetterBehavior ?? layoutManager.typesetterBehavior
        placeholderStorage.setAttributedString(NSAttributedString(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: placeholderColor,
        ]))
        let range = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: range, at: placeholderOrigin)
    }

    override func didChangeText() {
        super.didChangeText()
        // 从空到有字（或反过来）要重画一次，占位符才会出现 / 消失
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}
