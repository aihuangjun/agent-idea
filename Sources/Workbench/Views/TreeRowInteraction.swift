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
    /// 拖拽在剪贴板上的类型，只在应用内有效；值是节点绝对路径的数组（属性列表）——多选也只放**一个**剪贴板项，
    /// AppKit 对没有图像的额外拖拽项会直接不起拖拽（0.9.0 开发中多选拖不动就是这个）。
    static let pasteboardType = NSPasteboard.PasteboardType("local.agentidea.tree-node")

    /// 拖影长什么样。
    struct DragPreview {
        let title: String
        let systemImage: String
        let tint: NSColor
        /// 行里图标的横坐标：拖影从那里起步，看起来像把这一行提起来了。
        let leadingInset: CGFloat
    }

    /// 按下（位置是行内坐标，左上原点；带修饰键：⌘ / ⇧ 是多选）。
    var press: (CGPoint, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// 松开；参数是「没拖动、算一次点击」。起了拖拽的在拖拽结束时调，算不上点击。
    var release: (_ isClick: Bool) -> Void = { _ in }
    /// 这一行自己的路径（视图被回收给别的行用时靠它认出来）；nil 表示不能拖（根）。
    var dragPath: String?
    /// 这一行拖起来时剪贴板上放的路径：多选时是选中的那几个（拖起来那一刻才问，选中可能刚变）。
    var dragPaths: () -> [String] = { [] }
    /// 拖影长什么样，按拖起来的个数给（多个时是「N 个项目」）。
    var dragPreview: ((_ count: Int) -> DragPreview)?
    /// 别的行拖过来：这些来源路径能不能放到这里。nil 表示这一行不收拖放。
    var dropCheck: (([String]) -> Bool)?
    var drop: ([String]) -> Void = { _ in }
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

        init(configuration: TreeRowInteraction) {
            self.configuration = configuration
            super.init(frame: .zero)
            registerForDraggedTypes([TreeRowInteraction.pasteboardType])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        deinit {
            springLoadTimer?.invalidate()
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
            configuration.press(point, event.modifierFlags.intersection([.command, .shift, .option]))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownLocation, !isDragging, configuration.dragPath != nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard abs(point.x - start.x) >= Self.dragThreshold || abs(point.y - start.y) >= Self.dragThreshold else { return }
            let paths = configuration.dragPaths()
            guard !paths.isEmpty else { return }
            isDragging = true
            let item = NSPasteboardItem()
            item.setPropertyList(paths, forType: TreeRowInteraction.pasteboardType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            if let preview = configuration.dragPreview?(paths.count) {
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
            // 拖到窗口外面松手、按 Esc 取消：没有哪一行会收到 draggingEnded，自动滚动在这里停
            TreeAutoscroll.shared.stop()
            configuration.release(false)
        }

        // MARK: 拖放目标

        /// 剪贴板上拖着的路径（属性列表数组；单个字符串也认）；别的应用拖来的东西不认。
        static func paths(on pasteboard: NSPasteboard) -> [String] {
            (pasteboard.pasteboardItems ?? []).flatMap { item -> [String] in
                if let list = item.propertyList(forType: TreeRowInteraction.pasteboardType) as? [String] { return list }
                return item.string(forType: TreeRowInteraction.pasteboardType).map { [$0] } ?? []
            }
        }

        /// 剪贴板上这些东西能不能放到这一行：能就是「移动」，否则光标变成不允许。
        func dropOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
            let paths = Self.paths(on: pasteboard)
            guard !paths.isEmpty, let check = configuration.dropCheck, check(paths) else { return [] }
            return .move
        }

        @discardableResult
        func performDrop(from pasteboard: NSPasteboard) -> Bool {
            guard dropOperation(for: pasteboard) != [] else { return false }
            configuration.drop(Self.paths(on: pasteboard))
            return true
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) {
            setTargeted(false)
            TreeAutoscroll.shared.stop()
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            setTargeted(false)
            TreeAutoscroll.shared.stop()
            return performDrop(from: sender.draggingPasteboard)
        }

        /// 拖着东西在不在这一行上（能放才算）。按需起 spring loading 从这里走。
        func setTargeted(_ targeted: Bool) {
            isTargeted = targeted
        }

        private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = dropOperation(for: sender.draggingPasteboard)
            setTargeted(operation != [])
            // 自动滚动交给列表级的那一个：行会被滚出视野、被 LazyVStack 回收，挂在行上的定时器跟着停，往上拖时列表就不动了
            if let scrollView = enclosingScrollView { TreeAutoscroll.shared.start(in: scrollView) }
            return operation
        }

    }
}

/// 拖拽时列表的自动滚动，整个应用一个（同一时刻只会有一场拖拽）：每一拍看光标现在在哪、贴没贴边，贴了就往那边滚一点。
/// 不挂在行上：起滚动的那一行几拍之后就被滚出视野、被 LazyVStack 回收，挂在它身上的定时器一停，列表就不动了
/// （0.8.0 里往上拖滚不动就是这个原因——往下时下一行接上得快，往上时新露出来的行还没建好）。
/// 停的条件：松开了鼠标、光标离开边缘（或跑远了）、拖拽结束 / 放下（行报上来）。方向每一拍重算，光标从下边缘移到上边缘也跟得上。
@MainActor
final class TreeAutoscroll {
    static let shared = TreeAutoscroll()

    /// 离列表上下边缘多近开始滚、跑到列表外多远之内还算贴边、每一拍滚多少。
    static let margin: CGFloat = 28
    static let slack: CGFloat = 28
    static let step: CGFloat = 6

    /// 光标现在在窗口里的位置、鼠标是不是还按着：测试里换成假的（离屏窗口里合成不了真的拖拽）。
    var locationInWindow: (NSWindow) -> NSPoint = { $0.convertPoint(fromScreen: NSEvent.mouseLocation) }
    var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    var isRunning: Bool { timer != nil }

    func start(in scrollView: NSScrollView) {
        if self.scrollView !== scrollView { stop() }
        self.scrollView = scrollView
        guard timer == nil else { return }
        timer = TreeRowInteraction.View.schedule(after: 1 / 60, repeats: true) { [weak self] in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scrollView = nil
    }

    private func tick() {
        guard let scrollView, let window = scrollView.window, isMouseDown() else {
            stop()
            return
        }
        let clip = scrollView.contentView
        let point = clip.convert(locationInWindow(window), from: nil)
        let visible = clip.bounds
        // 横向跑出列表（拖到编辑区去了）也停：纵坐标恰好在贴边带里的话定时器会一直转
        guard point.x >= visible.minX - Self.slack, point.x <= visible.maxX + Self.slack, let direction = DragAutoscroll.direction(
            pointY: point.y, visibleMinY: visible.minY, visibleMaxY: visible.maxY, margin: Self.margin, slack: Self.slack
        ) else {
            stop()
            return
        }
        var origin = visible.origin
        origin.y += direction * Self.step
        // 到头了也不停：LazyVStack 的内容高度是边滚边长出来的，这一拍到头下一拍未必；光标离开边缘自然会停
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: visible.size)).origin
        guard constrained != visible.origin else { return }
        clip.scroll(to: constrained)
        scrollView.reflectScrolledClipView(clip)
    }
}
