import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

/// 同步地转一小会儿主 RunLoop（`RunLoop.run(until:)` 不让在 async 上下文里直接调）。
@MainActor private func spinRunLoop(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 离屏性能探针：把整个 WorkbenchView 放进一个**不显示**的窗口，合成鼠标事件点目录树，量「点击 → 选中行画出来」
/// 和「点击文件 → WebView 画完」的耗时。只在设了 AGENTIDEA_PERF=1 时跑，输出看 stdout。
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTIDEA_PERF"] != nil)) @MainActor
func probeTreeClickLatency() async throws {
    // 默认量本包自己；AGENTIDEA_PERF_ROOT 指别的项目，AGENTIDEA_PERF_FILES 用冒号分隔要打开的相对路径
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTIDEA_PERF_ROOT"] ?? String(#filePath.split(separator: "/Tests/")[0]))
    let defaults = UserDefaults(suiteName: "agentidea-perf-\(UUID().uuidString)")!
    let workbench = WorkbenchModel(git: GitClient.locate(), defaults: defaults, recentFile: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perf-recent.json"))
    workbench.openProject(root)
    let session = try #require(workbench.active)

    let view = WorkbenchView()
        .frame(width: 1200, height: 800)
        .environmentObject(workbench)
        .environmentObject(workbench.preferences)
        .environmentObject(Updater())
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    // 窗口放到屏幕外面（x = -20000）：合成事件要窗口真的存在于窗口服务器里才会被派发，但不能让用户看见、也不抢焦点
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderBack(nil)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 800_000_000)

    func click(at point: CGPoint, count: Int = 1) {
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
            window.sendEvent(event)
        }
    }
    func pump(_ seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        // 测试进程里没有 NSApplication 事件循环；直接转主 RunLoop 让 SwiftUI 的更新与 CA 事务跑起来
        while Date() < deadline {
            spinRunLoop(0.002)
            await Task.yield()
        }
    }

    // 树的行：工具条 40pt 之后，标题条 32 + 28 顶栏 + 4 padding；行高 22。第 i 行的中心 y（AppKit 坐标从下往上）
    func rowPoint(_ index: Int) -> CGPoint {
        let top = 28.0 + 32 + 4 + 22 + Double(index) * 22 + 11 // 28 顶栏、32 工具窗头、4 padding、22 根行
        return CGPoint(x: 40 + 120, y: 800 - top)
    }

    print("rows:", session.rows.count)
    var selectLatencies: [Double] = []
    for i in 0..<min(6, session.rows.count) {
        let started = ProcessInfo.processInfo.systemUptime
        click(at: rowPoint(i))
        // 等到 selectedPath 变化并且 SwiftUI 完成一次布局
        while session.selectedPath != session.rows[i].id, ProcessInfo.processInfo.systemUptime - started < 2 { await pump(0.002) }
        hosting.layoutSubtreeIfNeeded()
        let selectMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        selectLatencies.append(selectMs)
        print(String(format: "row %d select: %.1f ms  (%@)", i, selectMs, session.rows[i].node.name))
        await pump(0.4)
    }
    print("select median ms:", selectLatencies.sorted()[selectLatencies.count / 2])

    // 把树撑大：展开前两层目录，量大树上的选中耗时
    for row in session.rows where row.node.isDirectory { session.expand(row.id) }
    for row in session.rows where row.node.isDirectory && row.depth == 1 { session.expand(row.id) }
    for row in session.rows where row.node.isDirectory && row.depth == 2 { session.expand(row.id) }
    await pump(0.5)
    /// 做一个改动，量主线程什么时候才空下来（SwiftUI 的更新回合跑完）。
    func stall(_ label: String, _ action: @MainActor () -> Void) async {
        var samples: [Double] = []
        for _ in 0..<3 {
            let started = ProcessInfo.processInfo.systemUptime
            action()
            // 下一个 main-actor 任务排在 SwiftUI 的更新回合之后：它开始执行的时刻就是主线程空下来的时刻
            let done = Locked<Double?>(nil)
            Task { @MainActor in done.value = ProcessInfo.processInfo.systemUptime }
            while done.value == nil { await pump(0.001) }
            samples.append((done.value! - started) * 1000)
            await pump(0.1)
        }
        print(String(format: "stall %@ (%d rows): %@ ms", label, session.rows.count, samples.map { String(format: "%.1f", $0) }.joined(separator: " ")))
    }
    await stall("select", { session.select(session.rows[3].id) })
    await stall("unrelated publish (banner)", { session.dismissBanner() })
    await stall("refreshGit spinner", { session.refreshGit() })
    for row in session.rows where row.node.isDirectory && row.depth == 3 { session.expand(row.id) }
    for row in session.rows where row.node.isDirectory && row.depth == 4 { session.expand(row.id) }
    await pump(0.5)
    await stall("select", { session.select(session.rows[5].id) })
    await stall("unrelated publish (banner)", { session.dismissBanner() })
    await stall("refreshGit spinner", { session.refreshGit() })
    session.collapseAll()
    await pump(0.3)
    await stall("select", { session.select(session.rows[2].id) })
    await stall("unrelated publish (banner)", { session.dismissBanner() })
    // 悬停：鼠标扫过 30 行，量每次 hover 更新的耗时
    let hoverStarted = ProcessInfo.processInfo.systemUptime
    for i in 0..<30 {
        let point = rowPoint(i % 12)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        window.sendEvent(event)
        await pump(0.001)
    }
    hosting.layoutSubtreeIfNeeded()
    print(String(format: "30 hover moves: %.1f ms", (ProcessInfo.processInfo.systemUptime - hoverStarted) * 1000))

    // 打开几种大小的文件，量：标签出现 → 内容读完 → WebView 画完（render.js 自报的耗时另列）
    let renderedMs = Locked<Int?>(nil)
    workbench.renderer.onRendered = { _, ms in renderedMs.value = ms }
    let candidates = ProcessInfo.processInfo.environment["AGENTIDEA_PERF_FILES"]?.split(separator: ":").map(String.init)
        ?? ["README.md", "AGENTS.md", "Sources/Workbench/Model/ProjectSession.swift"]
    for relative in candidates {
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        renderedMs.value = nil
        let started = ProcessInfo.processInfo.systemUptime
        session.openFile(url, pinned: true)
        while session.activeContent == nil || session.activeContent == .loading, ProcessInfo.processInfo.systemUptime - started < 5 { await pump(0.002) }
        let loadedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        while renderedMs.value == nil, ProcessInfo.processInfo.systemUptime - started < 10 { await pump(0.002) }
        let doneMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print(String(format: "open %@ (%d B): loaded %.1f ms, rendered %.1f ms (render.js %d ms)", relative, size, loadedMs, doneMs, renderedMs.value ?? -1))
    }
}
