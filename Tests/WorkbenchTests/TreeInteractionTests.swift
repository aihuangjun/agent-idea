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

    let accepted = Locked<[String]>([])
    let targeted = Locked<[Bool]>([])
    let view = TreeRowInteraction.View(configuration: TreeRowInteraction(
        dragPath: "/p/a",
        dropCheck: { $0 == "/p/ok" },
        drop: { accepted.value.append($0) },
        onTargetChange: { targeted.value.append($0) }
    ))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("agentidea-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("/p/ok", forType: TreeRowInteraction.pasteboardType)
    #expect(view.dropOperation(for: pasteboard) == .move)
    #expect(view.performDrop(from: pasteboard))
    #expect(accepted.value == ["/p/ok"])

    pasteboard.clearContents()
    pasteboard.setString("/p/no", forType: TreeRowInteraction.pasteboardType)
    #expect(view.dropOperation(for: pasteboard) == [])
    #expect(!view.performDrop(from: pasteboard))
    pasteboard.clearContents()
    pasteboard.setString("/p/ok", forType: .string)
    #expect(view.dropOperation(for: pasteboard) == [], "别的应用拖来的文字不收")
    #expect(accepted.value == ["/p/ok"])

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
    TreeRowInteraction.View.springLoadDelay = 0.1
    defer { TreeRowInteraction.View.springLoadDelay = original }
    let expanded = Locked(0)
    let view = TreeRowInteraction.View(configuration: TreeRowInteraction(dropCheck: { _ in true }, springLoad: { expanded.value += 1 }))
    view.setTargeted(true)
    spin(0.03)
    view.setTargeted(false)
    spin(0.15)
    #expect(expanded.value == 0, "停得不够久就离开了")
    view.setTargeted(true)
    spin(0.25, mode: .eventTracking)
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
