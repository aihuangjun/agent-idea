import AppKit
import SwiftUI

// KBReader Sources/AIChat/UI/ComposerTextView.swift: growing NSTextView and focus-local key handling.
struct WorkspaceChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let focusTick: Int
    let onSubmit: () -> Void
    let onEscape: () -> Bool
    let addReferences: ([URL]) -> Void

    static let font = NSFont.systemFont(ofSize: 13)
    static let maxLines: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WorkspaceChatScrollView()
        // 抽屉拉宽拉窄时没有文字变化，也得按新宽度重算折行后的高度。
        scroll.onTile = { [weak coordinator = context.coordinator] in coordinator?.recalculateHeight() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = WorkspaceChatPlaceholder()
        textView.placeholder = placeholder
        textView.addReferences = addReferences
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.string] + WorkspaceChatReferenceDrop.types)
        textView.setAccessibilityIdentifier("ai-chat-input")
        textView.setAccessibilityLabel("给 AI 发消息")
        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.recalculateHeight()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.placeholder = placeholder
        textView.addReferences = addReferences
        // 外面改了草稿（补全、发送后清空）才回写；组字中不动，否则拼音候选被打断。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // 整段换掉之后旧的撤销记录指着已经不存在的范围，⌘Z 会撤出乱码甚至越界。
            textView.undoManager?.removeAllActions()
        }
        coordinator.recalculateHeight()
        if coordinator.lastFocusTick != focusTick {
            coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WorkspaceChatInput
        weak var textView: WorkspaceChatPlaceholder?
        var lastFocusTick: Int
        private let history = UndoManager()

        init(_ parent: WorkspaceChatInput) {
            self.parent = parent
            self.lastFocusTick = parent.focusTick
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            recalculateHeight()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { history }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // 系统在组字时本就不走这里；多一道保险，候选里的回车、方向键、Esc 永远归输入法。
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if Self.currentEventAsksForNewline() {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                // ⌥回车走的是 insertNewlineIgnoringFieldEditor:，NSTextView 自己就换行。
                return false
            }
        }

        /// 这次回车是不是「要换行」：小键盘 Enter（笔记本上的 fn+回车）或带 fn/⇧/⌥。
        static func currentEventAsksForNewline() -> Bool {
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
            let flags = event.modifierFlags
            return event.keyCode == 76 || !flags.intersection([.function, .shift, .option]).isEmpty
        }

        func recalculateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let line = ceil(WorkspaceChatInput.font.ascender - WorkspaceChatInput.font.descender + WorkspaceChatInput.font.leading)
            let used = layout.usedRect(for: container).height
            let content = max(used, line) + textView.textContainerInset.height * 2
            let capped = min(content, line * WorkspaceChatInput.maxLines + textView.textContainerInset.height * 2)
            let rounded = ceil(capped)
            if abs(parent.height - rounded) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = rounded }
            }
        }
    }
}

final class WorkspaceChatScrollView: NSScrollView {
    var onTile: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func tile() {
        super.tile()
        guard abs(contentSize.width - lastWidth) > 0.5 else { return }
        lastWidth = contentSize.width
        onTile?()
    }
}

/// 自己画占位符的 NSTextView：起点、字体与正文完全一致。
final class WorkspaceChatPlaceholder: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var addReferences: ([URL]) -> Void = { _ in }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        WorkspaceChatReferenceDrop.urls(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        WorkspaceChatReferenceDrop.urls(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !WorkspaceChatReferenceDrop.urls(from: sender).isEmpty || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = WorkspaceChatReferenceDrop.urls(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        addReferences(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerOrigin.y
        )
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? WorkspaceChatInput.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}
