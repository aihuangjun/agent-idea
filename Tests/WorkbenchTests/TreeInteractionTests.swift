import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// 同步地转一小会儿主 RunLoop（可指定模式：拖拽期间是 eventTracking）。
@MainActor private func spin(_ seconds: TimeInterval, mode: RunLoop.Mode = .default) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: mode, before: min(deadline, Date().addingTimeInterval(0.02)))
    }
}

/// 交互层的判定：右键 / ⌃点击放行给 SwiftUI；拖放只认应用内的类型，且要过 `dropCheck`。
@Test @MainActor func treeRowInteractionDecidesContextClicksAndDrops() throws {
    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }
    #expect(TreeRowInteraction.View.isContextClick(event(.rightMouseDown)))
    #expect(TreeRowInteraction.View.isContextClick(event(.leftMouseDown, flags: .control)))
    #expect(!TreeRowInteraction.View.isContextClick(event(.leftMouseDown)))

    let accepted = Locked<[[String]]>([])
    let targeted = Locked<[Bool]>([])
    let view = TreeRowInteraction.View(configuration: TreeRowInteraction(
        dragPath: "/p/a",
        dropCheck: { $0.allSatisfy { $0.hasPrefix("/p/ok") } },
        drop: { accepted.value.append($0) },
        onTargetChange: { targeted.value.append($0) }
    ))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("agentidea-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("/p/ok", forType: TreeRowInteraction.pasteboardType)
    #expect(view.dropOperation(for: pasteboard) == .move)
    #expect(view.performDrop(from: pasteboard))
    #expect(accepted.value == [["/p/ok"]])

    // 多选拖过来：一个剪贴板项里放路径数组，一起交给 drop
    pasteboard.clearContents()
    let multiple = NSPasteboardItem()
    multiple.setPropertyList(["/p/ok1", "/p/ok2"], forType: TreeRowInteraction.pasteboardType)
    pasteboard.writeObjects([multiple])
    #expect(TreeRowInteraction.View.paths(on: pasteboard) == ["/p/ok1", "/p/ok2"])
    #expect(view.performDrop(from: pasteboard))
    #expect(accepted.value.last == ["/p/ok1", "/p/ok2"])

    pasteboard.clearContents()
    pasteboard.setString("/p/no", forType: TreeRowInteraction.pasteboardType)
    #expect(view.dropOperation(for: pasteboard) == [])
    #expect(!view.performDrop(from: pasteboard))
    pasteboard.clearContents()
    pasteboard.setString("/p/ok", forType: .string)
    #expect(view.dropOperation(for: pasteboard) == [], "别的应用拖来的文字不收")
    #expect(accepted.value.count == 2)

    // 不收拖放的行（没有 dropCheck）
    let plain = TreeRowInteraction.View(configuration: TreeRowInteraction())
    pasteboard.clearContents()
    pasteboard.setString("/p/ok", forType: TreeRowInteraction.pasteboardType)
    #expect(plain.dropOperation(for: pasteboard) == [])

    // 拖影：图标 + 名字，宽度随名字变
    let short = TreeRowInteraction.View.image(for: .init(title: "a", systemImage: "doc", tint: .white, leadingInset: 0))
    let long = TreeRowInteraction.View.image(for: .init(title: "a-much-longer-file-name.swift", systemImage: "doc", tint: .white, leadingInset: 0))
    #expect(short.size.height == 22 && long.size.width > short.size.width + 100)
}

/// 拖着东西在折叠目录上停够 0.6s 才展开，中途离开就不展开。拖拽期间 AppKit 的事件循环跑在 eventTracking 模式，
/// 定时器在那个模式下也得响（只挂 default 模式的不会）。
@Test @MainActor func springLoadingFiresAfterHoveringLongEnough() async {
    // 别在主线程上转太久：并发跑的别的测试等 git 的期限会被耗掉
    let original = TreeRowInteraction.View.springLoadDelay
    // 0.3 秒而不是 0.1：下面「停得不够久」那一段要明显短于它。机器忙的时候 RunLoop 转一小会儿也可能拖长，
    // 阈值太小的话那一段会意外跨过定时器，用例反过来红
    TreeRowInteraction.View.springLoadDelay = 0.3
    defer { TreeRowInteraction.View.springLoadDelay = original }
    let expanded = Locked(0)
    let view = TreeRowInteraction.View(configuration: TreeRowInteraction(dropCheck: { _ in true }, springLoad: { expanded.value += 1 }))
    view.setTargeted(true)
    spin(0.05)
    view.setTargeted(false)
    spin(0.4)
    #expect(expanded.value == 0, "停得不够久就离开了")

    view.setTargeted(true)
    // 等它响，最多 5 秒（原来固定转 0.25 秒：并行跑的时候这一拍常常迟到，用例就红了）。
    // 转一小段就 yield 一次，别把别的 @MainActor 测试饿住
    let deadline = Date().addingTimeInterval(5)
    while expanded.value == 0, Date() < deadline {
        spin(0.02, mode: .eventTracking)
        await Task.yield()
    }
    #expect(expanded.value == 1, "拖拽的事件循环模式下要响")
    view.setTargeted(false)
    spin(0.2)
    #expect(expanded.value == 1, "只展开一次")
}

/// 视图被 SwiftUI 回收给别的行、或从视图树里拆掉时，正亮着的高亮要按旧身份撤掉，排着的 spring loading 也要取消。
@Test @MainActor func treeRowInteractionResetClearsTargetAndTimers() {
    let targeted = Locked<[Bool]>([])
    let expanded = Locked(0)
    let view = TreeRowInteraction.View(configuration: TreeRowInteraction(
        dragPath: "/p/a", dropCheck: { _ in true }, onTargetChange: { targeted.value.append($0) }, springLoad: { expanded.value += 1 }
    ))
    let original = TreeRowInteraction.View.springLoadDelay
    TreeRowInteraction.View.springLoadDelay = 0.1
    defer { TreeRowInteraction.View.springLoadDelay = original }
    view.setTargeted(true)
    view.apply(TreeRowInteraction(dragPath: "/p/b"))
    #expect(targeted.value == [true, false], "换了身份先按旧身份撤高亮")
    spin(0.25)
    #expect(expanded.value == 0, "旧节点的自动展开不能再触发")
}

/// 树里「拖拽经过哪一行」的状态：离开只能撤自己那一行建立的高亮。
@Test func dropTargetStateSurvivesReversedEnterAndExit() {
    var state = DropTargetState()
    state.enter(row: "/p/a.txt", directory: "/p")
    // 相邻的文件行代表同一个目录：AppKit 先报新行进入、再报旧行离开
    state.enter(row: "/p/b.txt", directory: "/p")
    state.clear(row: "/p/a.txt")
    #expect(state.directory == "/p", "旧行的离开不能清掉新行的高亮")
    state.clear(row: "/p/b.txt")
    #expect(state.directory == nil)
}

/// 把项目树放进离屏窗口合成点击：按下就选中（交互层换成 NSView 之后行为不能变），同一行两下打开文件，
/// 目录行的箭头区域按下就展开。
@Test @MainActor func treeRowsRespondToSynthesizedClicks() async throws {
    try await withTemporaryDirectory { directory in
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "i".write(to: directory.appendingPathComponent("sub/inner.txt"), atomically: true, encoding: .utf8)
        try "t".write(to: directory.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        let session = ProjectSession(root: directory, git: nil, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        session.setActive(true)

        let size = CGSize(width: 320, height: 400)
        let hosting = NSHostingView(rootView: ProjectTreeView(session: session).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        FirstMouse.enableGlobally()
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        defer { window.orderOut(nil) }

        // 行的位置：标题条 32 + 上边距 4 + 根那一行 22，然后每行 22
        func rowPoint(_ index: Int, x: CGFloat = 120) -> CGPoint {
            let top = 32.0 + 4 + 22 + Double(index) * 22 + 11
            return CGPoint(x: x, y: size.height - top)
        }
        @MainActor func send(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 0)!
            window.sendEvent(event)
        }
        @MainActor func settle(_ seconds: TimeInterval = 0.3) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                spin(0.01)
                await Task.yield()
            }
            hosting.layoutSubtreeIfNeeded()
        }

        // 行 0 是 sub，行 1 是 top.txt。按下就选中
        send(.leftMouseDown, at: rowPoint(1))
        #expect(session.selectedPath == directory.appendingPathComponent("top.txt").path, "按下就该选中")
        send(.leftMouseUp, at: rowPoint(1))
        // 打开是在松开时同步做的，这里不用等；也不能等——并发跑的别的测试会把主线程占住，一等就超过双击间隔
        #expect(session.tabs.isEmpty, "一下不打开")

        // 同一行在双击间隔内再点一下：打开
        send(.leftMouseDown, at: rowPoint(1), clickCount: 2)
        send(.leftMouseUp, at: rowPoint(1), clickCount: 2)
        await settle()
        #expect(session.tabs.first?.title == "top.txt")

        // 目录行的箭头区域：按下就展开
        send(.leftMouseDown, at: rowPoint(0, x: 12))
        send(.leftMouseUp, at: rowPoint(0, x: 12))
        await settle()
        #expect(session.rows.map(\.node.name) == ["sub", "inner.txt", "top.txt"])

        // AGENTIDEA_SNAPSHOT_DIR 设了就把树的样子导出来看
        if let snapshotDirectory = ProcessInfo.processInfo.environment["AGENTIDEA_SNAPSHOT_DIR"],
           let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("project-tree.png"))
        }
    }
}

/// 拖到列表上下边缘附近要自动滚动，往上往下都要能滚到头（0.8.0 里往上滚不动：定时器挂在行上，行一被回收就停了）。
/// 拖拽会话本身起不来，把「光标在哪」换成假的直接喂给列表级的自动滚动。
@Test @MainActor func draggingNearEdgesAutoscrollsBothWays() async throws {
    try await withTemporaryDirectory { directory in
        for index in 0..<24 {
            try "x".write(to: directory.appendingPathComponent(String(format: "file-%02d.txt", index)), atomically: true, encoding: .utf8)
        }
        let session = ProjectSession(root: directory, git: nil, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        session.setActive(true)
        let size = CGSize(width: 320, height: 300)
        let hosting = NSHostingView(rootView: ProjectTreeView(session: session).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        func find<T: NSView>(_: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews { if let match = find(T.self, in: child) { return match } }
            return nil
        }
        // 等 SwiftUI 把行摆出来、内容比视野高（有得滚才谈得上自动滚动）。
        // 原来是硬睡 500ms：机器忙起来不够用，行还没摆完就开始滚，滚不到底
        let laidOut = Date().addingTimeInterval(10)
        while Date() < laidOut {
            hosting.layoutSubtreeIfNeeded()
            if let scroll = find(NSScrollView.self, in: hosting),
               (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 100 { break }
            spin(0.02)
            await Task.yield()
        }
        let scrollView = try #require(find(NSScrollView.self, in: hosting))
        #expect((scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height + 100, "内容要比视野高才有得滚")
        let clip = scrollView.contentView
        /// 视野离文档顶端 / 底端还有多远（视觉上的，与坐标系翻不翻转无关）。
        func distanceFromTop() -> CGFloat {
            let document = clip.documentView?.bounds ?? .zero
            return clip.isFlipped ? clip.documentVisibleRect.minY : document.maxY - clip.documentVisibleRect.maxY
        }
        func distanceFromBottom() -> CGFloat {
            let document = clip.documentView?.bounds ?? .zero
            return clip.isFlipped ? document.maxY - clip.documentVisibleRect.maxY : clip.documentVisibleRect.minY
        }
        // 转一小段就 yield 一次：一口气转几秒会把并行跑的别的 @MainActor 测试饿住（见 AGENTS.md）。
        // 超时给得宽（自动滚动是定时器驱动的，机器忙时每一拍都可能迟到），条件一成立就返回
        @MainActor func spinUntil(_ seconds: TimeInterval, _ done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !done() {
                spin(0.02)
                await Task.yield()
            }
        }
        let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)   // 窗口坐标 y 向上：maxY 是视觉上的顶边
        #expect(distanceFromTop() == 0)

        let autoscroll = TreeAutoscroll.shared
        let cursor = Locked(NSPoint(x: frameInWindow.midX, y: frameInWindow.minY + 8))
        let mouseDown = Locked(true)
        autoscroll.locationInWindow = { _ in cursor.value }
        autoscroll.isMouseDown = { mouseDown.value }
        defer {
            autoscroll.stop()
            autoscroll.locationInWindow = { $0.convertPoint(fromScreen: NSEvent.mouseLocation) }
            autoscroll.isMouseDown = { NSEvent.pressedMouseButtons != 0 }
        }

        // 贴着下边缘往下滚到底（内容高度是边滚边长的，到头那一拍不能停）
        autoscroll.start(in: scrollView)
        await spinUntil(10) { distanceFromBottom() < 8 }
        #expect(distanceFromBottom() < 8, "往下滚到头（差的那几个点是列表底部的内边距）")
        #expect(distanceFromTop() > 100)
        #expect(autoscroll.isRunning, "光标还贴着边就不停")

        // 光标挪到上边缘（甚至跑到列表上面一点，标题条上）：往上滚回顶
        cursor.value = NSPoint(x: frameInWindow.midX, y: frameInWindow.maxY + 10)
        await spinUntil(10) { distanceFromTop() < 8 }
        #expect(distanceFromTop() < 8, "往上滚到头")

        // 光标回到中间：停；松开鼠标：停
        cursor.value = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
        await spinUntil(5) { !autoscroll.isRunning }
        #expect(!autoscroll.isRunning)
        autoscroll.start(in: scrollView)
        mouseDown.value = false
        await spinUntil(5) { !autoscroll.isRunning }
        #expect(!autoscroll.isRunning)
    }
}

/// 从变更列表「在项目视图中显示」：定位的那一刻树视图还不在界面上（工具窗口正显示着变更列表），切过去才被建出来。
/// 它一出现就得把那一行滚进视野（1.2.0 前选中了，但滚动条停在顶上，要自己往下找）；树已经在界面上时再定位也照滚。
@Test @MainActor func revealScrollsTheTreeEvenWhenItAppearsAfterwards() async throws {
    try await withTemporaryDirectory { directory in
        for index in 0..<60 {
            try "x".write(to: directory.appendingPathComponent(String(format: "file-%02d.txt", index)), atomically: true, encoding: .utf8)
        }
        let session = ProjectSession(root: directory, git: nil, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        let target = directory.appendingPathComponent("file-55.txt")
        session.reveal(target)
        #expect(session.pendingReveal == target.path)

        let size = CGSize(width: 320, height: 300)
        let hosting = NSHostingView(rootView: ProjectTreeView(session: session).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func find<T: NSView>(_: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews { if let match = find(T.self, in: child) { return match } }
            return nil
        }
        /// 第 `index` 行（不算根那一行）整个在视野里。行在文档里的位置：上边距 4 + 根那一行 22，然后每行 22。
        func isVisible(row index: Int) -> Bool {
            hosting.layoutSubtreeIfNeeded()
            guard let clip = find(NSScrollView.self, in: hosting)?.contentView, let document = clip.documentView?.bounds else { return false }
            let visible = clip.documentVisibleRect
            let top = clip.isFlipped ? visible.minY : document.maxY - visible.maxY
            let rowTop = 4 + 22 + CGFloat(index) * 22
            return rowTop >= top && rowTop + 22 <= top + visible.height
        }
        @MainActor func spinUntil(_ seconds: TimeInterval, _ done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !done() {
                spin(0.02)
                await Task.yield()
            }
        }

        await spinUntil(10) { isVisible(row: 55) && session.pendingReveal == nil }
        #expect(isVisible(row: 55), "树一出现就滚到定位的那一行")
        #expect(!isVisible(row: 0))
        #expect(session.pendingReveal == nil, "滚完就不欠了")

        // 树已经在界面上：再定位到上面的一行，滚回去
        session.reveal(directory.appendingPathComponent("file-02.txt"))
        await spinUntil(10) { isVisible(row: 2) }
        #expect(isVisible(row: 2))
        #expect(session.selectedPath == directory.appendingPathComponent("file-02.txt").path)
    }
}

/// 分支弹窗能排出来：新建分支、本地分支、远程分支三段都在。设了 AGENTIDEA_SNAPSHOT_DIR 就把样子导出来看。
@Test @MainActor func branchPopupLaysOutSections() async throws {
    try await withTemporaryDirectory { directory in
        let session = ProjectSession(root: directory, git: nil, renderer: ContentRenderer(),
                                     preferences: ReadingPreferences(defaults: UserDefaults(suiteName: "agentidea-tests-\(UUID().uuidString)")!))
        session.branchList = GitBranchList.parse(
            "refs/heads/feat/retrieval-four-lanes\u{1f}\u{1f}*\nrefs/heads/master\u{1f}origin/master\u{1f} \nrefs/remotes/origin/master\u{1f}\u{1f} \nrefs/remotes/origin/dev\u{1f}\u{1f} \n",
            remotes: ["origin"], remoteHead: "origin/master")
        let hosting = NSHostingView(rootView: BranchPopup(session: session))
        let size = hosting.fittingSize
        #expect(size.width == 340 && size.height > 150, "\(size)")
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        if let snapshotDirectory = ProcessInfo.processInfo.environment["AGENTIDEA_SNAPSHOT_DIR"],
           let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("branch-popup.png"))
        }
    }
}
