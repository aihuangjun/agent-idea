import AppKit
import Core
import DesignSystem
import SwiftUI

/// 目录树一行的鼠标交互层（NSView 直包）：按下即选中、松开结算点击、拖过阈值起拖拽、每一行都是拖放目标（IDEA 的 Move）。
///
/// 为什么不用 SwiftUI：树的按下/松开原来是 `DragGesture(minimumDistance: 0)`（`PressGesture`），它与 `.onDrag`
/// 争同一个 mouseDown，谁赢没有保证；AppKit 里 mouseDown → mouseDragged → beginDraggingSession 是一条清楚的路，
/// 拖放目标也是标准的 `registerForDraggedTypes`。右键与 ⌃点击放行（`hitTest` 返回 nil），SwiftUI 的 `.contextMenu` 照常弹。
///
/// 拖拽的手感照访达 / IDEA：拖影是「图标 + 名字」的半透明小块（不是整行截图），在折叠的目录上停一会儿自动展开
/// （spring loading），拖到列表上下边缘附近自动滚动。
struct TreeRowInteraction: NSViewRepresentable {
    /// 拖拽在剪贴板上的类型，只在应用内有效；值是节点的绝对路径。
    static let pasteboardType = NSPasteboard.PasteboardType("local.agentidea.tree-node")

    /// 拖影长什么样。
    struct DragPreview {
        let title: String
        let systemImage: String
        let tint: NSColor
        /// 行里图标的横坐标：拖影从那里起步，看起来像把这一行提起来了。
        let leadingInset: CGFloat
    }

    /// 按下（位置是行内坐标，左上原点）。
    var press: (CGPoint) -> Void = { _ in }
    /// 松开；参数是「没拖动、算一次点击」。起了拖拽的在拖拽结束时调，算不上点击。
    var release: (_ isClick: Bool) -> Void = { _ in }
    /// 这一行拖起来时剪贴板上放的路径；nil 表示不能拖（根）。
    var dragPath: String?
    var dragPreview: DragPreview?
    /// 别的行拖过来：这个来源路径能不能放到这里。nil 表示这一行不收拖放。
    var dropCheck: ((String) -> Bool)?
    var drop: (String) -> Void = { _ in }
    /// 拖着东西经过、且能放：行据此画高亮。
    var onTargetChange: (Bool) -> Void = { _ in }
    /// 拖着东西在这一行上停了一会儿（折叠的目录借此自动展开）。nil 表示这一行没有这回事。
    var springLoad: (() -> Void)?

    func makeNSView(context: Context) -> View { View(configuration: self) }

    /// SwiftUI 会把这个 NSView 换给别的行用（LazyVStack 里的行会被回收）：正被拖着经过时换了身份，先按旧身份把高亮撤掉。
    func updateNSView(_ view: View, context: Context) { view.apply(self) }

    static func dismantleNSView(_ view: View, coordinator: ()) { view.reset() }

    final class View: NSView, NSDraggingSource {
        var configuration: TreeRowInteraction
        private var mouseDownLocation: CGPoint?
        private var isDragging = false
        private var springLoadTimer: Timer?
        private var autoscrollTimer: Timer?
        private(set) var isTargeted = false {
            didSet {
                guard isTargeted != oldValue else { return }
                configuration.onTargetChange(isTargeted)
                springLoadTimer?.invalidate()
                springLoadTimer = nil
                if isTargeted, let springLoad = configuration.springLoad {
                    springLoadTimer = Self.schedule(after: Self.springLoadDelay, repeats: false) { springLoad() }
                }
            }
        }

        /// 拖动多远才算拖（点击时手抖几个点不该起拖拽）。
        static let dragThreshold: CGFloat = 4
        /// 在折叠目录上停多久自动展开（访达约 0.6s）。测试里会调短。
        static var springLoadDelay: TimeInterval = 0.6
        /// 离列表上下边缘多近开始自动滚动，每一拍滚多少。
        static let autoscrollMargin: CGFloat = 28
        static let autoscrollStep: CGFloat = 6

        init(configuration: TreeRowInteraction) {
            self.configuration = configuration
            super.init(frame: .zero)
            registerForDraggedTypes([TreeRowInteraction.pasteboardType])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        deinit {
            springLoadTimer?.invalidate()
            autoscrollTimer?.invalidate()
        }

        /// 换上新配置。身份（拖起来的路径）变了说明这个视图被回收给别的行用了：先按旧配置把高亮撤掉。
        func apply(_ configuration: TreeRowInteraction) {
            if self.configuration.dragPath != configuration.dragPath { reset() }
            self.configuration = configuration
        }

        /// 这一行不再是现在这个样子了（被回收给别的节点、从视图树里拆掉）：按当前配置把高亮撤掉、定时器停掉、拖拽状态清零。
        func reset() {
            setTargeted(false)
            mouseDownLocation = nil
            isDragging = false
        }

        /// 拖拽期间 AppKit 的事件循环跑在 eventTracking 模式，只挂在 default 模式上的定时器一下都不会响；挂到 common 模式才两边都响。
        static func schedule(after interval: TimeInterval, repeats: Bool, _ body: @escaping @MainActor () -> Void) -> Timer {
            let timer = Timer(timeInterval: interval, repeats: repeats) { _ in MainActor.assumeIsolated { body() } }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }

        /// 行内坐标用左上原点，与 SwiftUI 一致（`TreeRow.pressed(at:)` 按横坐标判断箭头区域）。
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// 右键、⌃点击不接：让它们落到下面的 SwiftUI 行上，`.contextMenu` 才会弹。
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil else { return nil }
            if let event = NSApp.currentEvent, Self.isContextClick(event) { return nil }
            return self
        }

        static func isContextClick(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return true
            case .leftMouseDown: return event.modifierFlags.contains(.control)
            default: return false
            }
        }

        // MARK: 按下 / 松开 / 拖起

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            mouseDownLocation = point
            isDragging = false
            configuration.press(point)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownLocation, !isDragging, let path = configuration.dragPath else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard abs(point.x - start.x) >= Self.dragThreshold || abs(point.y - start.y) >= Self.dragThreshold else { return }
            isDragging = true
            let item = NSPasteboardItem()
            item.setString(path, forType: TreeRowInteraction.pasteboardType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            if let preview = configuration.dragPreview {
                let image = Self.image(for: preview)
                dragging.setDraggingFrame(
                    CGRect(x: preview.leadingInset - 8, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height),
                    contents: image
                )
            } else {
                dragging.setDraggingFrame(bounds, contents: nil)
            }
            let session = beginDraggingSession(with: [dragging], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = mouseDownLocation else { return }
            mouseDownLocation = nil
            guard !isDragging else { return }
            let point = convert(event.locationInWindow, from: nil)
            configuration.release(abs(point.x - start.x) < Self.dragThreshold && abs(point.y - start.y) < Self.dragThreshold)
        }

        /// 拖影：圆角小块上一个图标加名字，半透明——访达拖文件、IDEA 拖节点都是这个样子，比截一整行清楚。
        static func image(for preview: DragPreview) -> NSImage {
            let font = NSFont.systemFont(ofSize: 13)
            let text = NSAttributedString(string: preview.title, attributes: [.font: font, .foregroundColor: NSColor(Theme.text)])
            let textSize = text.size()
            let height: CGFloat = 22, iconSize: CGFloat = 16, padding: CGFloat = 8, gap: CGFloat = 6
            let width = padding + iconSize + gap + ceil(textSize.width) + padding + 2
            return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                NSColor(Theme.panel).withAlphaComponent(0.92).setFill()
                shape.fill()
                NSColor(Theme.border).setStroke()
                shape.stroke()
                let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(.init(paletteColors: [preview.tint]))
                if let symbol = NSImage(systemSymbolName: preview.systemImage, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    let size = symbol.size
                    symbol.draw(in: CGRect(x: padding + (iconSize - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height))
                }
                text.draw(at: NSPoint(x: padding + iconSize + gap, y: (height - textSize.height) / 2))
                return true
            }
        }

        // MARK: 拖拽来源

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // 只在应用内移动；拖到访达、别的应用上不给
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            mouseDownLocation = nil
            configuration.release(false)
        }

        // MARK: 拖放目标

        /// 剪贴板上这个东西能不能放到这一行：能就是「移动」，否则光标变成不允许。
        func dropOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
            guard let path = pasteboard.string(forType: TreeRowInteraction.pasteboardType), let check = configuration.dropCheck, check(path) else { return [] }
            return .move
        }

        @discardableResult
        func performDrop(from pasteboard: NSPasteboard) -> Bool {
            guard dropOperation(for: pasteboard) != [], let path = pasteboard.string(forType: TreeRowInteraction.pasteboardType) else { return false }
            configuration.drop(path)
            return true
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            setTargeted(false)
            return performDrop(from: sender.draggingPasteboard)
        }

        /// 拖着东西在不在这一行上（能放才算）。停下自动滚动、按需起 spring loading 都从这里走。
        func setTargeted(_ targeted: Bool) {
            isTargeted = targeted
            if !targeted { stopAutoscroll() }
        }

        private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = dropOperation(for: sender.draggingPasteboard)
            setTargeted(operation != [])
            autoscrollIfNearEdge(sender.draggingLocation)
            return operation
        }

        // MARK: 自动滚动

        /// 拖到列表上下边缘附近：往那个方向滚，直到离开边缘或拖拽结束。SwiftUI 的 ScrollView 在 macOS 上就是 NSScrollView。
        private func autoscrollIfNearEdge(_ locationInWindow: NSPoint) {
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            let point = clip.convert(locationInWindow, from: nil)
            let visible = clip.bounds
            // 往 bounds.origin.y 减小的方向是「视觉上的上」还是「下」取决于坐标系是否翻转
            let direction: CGFloat
            if point.y < visible.minY + Self.autoscrollMargin {
                direction = -1
            } else if point.y > visible.maxY - Self.autoscrollMargin {
                direction = 1
            } else {
                stopAutoscroll()
                return
            }
            guard autoscrollTimer == nil else { return }
            autoscrollTimer = Self.schedule(after: 1 / 60, repeats: true) { [weak self, weak scrollView] in
                guard let scrollView else { self?.stopAutoscroll(); return }
                let clip = scrollView.contentView
                var origin = clip.bounds.origin
                origin.y += direction * Self.autoscrollStep
                let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
                guard constrained != clip.bounds.origin else { self?.stopAutoscroll(); return }
                clip.scroll(to: constrained)
                scrollView.reflectScrolledClipView(clip)
            }
        }

        private func stopAutoscroll() {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
        }
    }
}
