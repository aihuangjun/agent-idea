import AppKit
import SwiftUI

/// 单行输入框（NSTextField 直包）。
///
/// 为什么不用 SwiftUI 的 `TextField`：它的 `@FocusState` 在正文 WKWebView 是第一响应者时常常拿不到焦点
/// （⌘F 打开搜索框、光标却还在编辑器里），而且没法指定初始选中的范围（重命名对话框要选到扩展名之前）。
/// 这里直接 `makeFirstResponder`，`focusRequests` 每变一次再抢一次；↑ ↓ 回车 Esc 交给 `onKey`，返回 true 表示吃掉。
public struct FocusedTextField: NSViewRepresentable {
    public enum Key { case up, down, submit, cancel }

    @Binding private var text: String
    private let placeholder: String
    private let focusRequests: Int
    private let initialSelection: Range<String.Index>?
    private let onKey: (Key) -> Bool
    private let onFocusChange: (Bool) -> Void

    /// - Parameters:
    ///   - focusRequests: 变了就再抢一次焦点（比如搜索框已经开着又按了 ⌘F）。挂上窗口时总会抢一次。
    ///   - initialSelection: 第一次拿到焦点时选中的那一段；nil 则全选（AppKit 的默认）。
    public init(
        text: Binding<String>, placeholder: String = "", focusRequests: Int = 0, initialSelection: Range<String.Index>? = nil,
        onKey: @escaping (Key) -> Bool = { _ in false }, onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        _text = text
        self.placeholder = placeholder
        self.focusRequests = focusRequests
        self.initialSelection = initialSelection
        self.onKey = onKey
        self.onFocusChange = onFocusChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = NSColor(Theme.text)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.stringValue = text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(Theme.mutedText),
        ])
        field.onAttach = { [weak field] in
            guard let field else { return }
            context.coordinator.focus(field, selecting: initialSelection)
        }
        field.onFocus = { context.coordinator.parent.onFocusChange(true) }
        context.coordinator.seenFocusRequests = focusRequests
        return field
    }

    public func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.seenFocusRequests != focusRequests {
            context.coordinator.seenFocusRequests = focusRequests
            context.coordinator.focus(field, selecting: nil)
        }
    }

    /// 挂上窗口时通知一声（`makeNSView` 时还没有窗口，抢不了焦点）；成为第一响应者时也通知。
    public final class Field: NSTextField {
        var onAttach: () -> Void = {}
        var onFocus: () -> Void = {}

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach() }
        }

        public override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus() }
            return accepted
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedTextField
        var seenFocusRequests = 0
        private var hasSelectedInitially = false

        init(_ parent: FocusedTextField) { self.parent = parent }

        func focus(_ field: NSTextField, selecting range: Range<String.Index>?) {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            // 字段编辑器是窗口共用的，选中色每次拿到焦点都设一遍
            editor.insertionPointColor = NSColor(Theme.text)
            editor.selectedTextAttributes = [.backgroundColor: NSColor(Theme.selection), .foregroundColor: NSColor(Theme.text)]
            if !hasSelectedInitially, let range {
                hasSelectedInitially = true
                editor.selectedRange = NSRange(range, in: field.stringValue)
            }
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        public func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: Key
            switch selector {
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.insertNewline(_:)): key = .submit
            case #selector(NSResponder.cancelOperation(_:)): key = .cancel
            default: return false
            }
            return parent.onKey(key)
        }
    }
}
