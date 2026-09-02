import AppKit
import Core
import DesignSystem
import Foundation
import Testing
import TestSupport
@preconcurrency import WebKit

/// 离屏渲染性能探针：给几个真实文件，量 render.js 自报的耗时与消息往返。
/// 只在 AGENTIDEA_PERF=1 时跑，文件用 AGENTIDEA_PERF_FILES=a:b:c 传绝对路径；输出看 stdout。
/// 注意离屏窗口不会合成/绘制，量不到画到屏幕上的那一段。
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTIDEA_PERF"] != nil)) @MainActor
func probeRenderCost() async throws {
    let renderer = ContentRenderer()
    let webView = renderer.webView
    webView.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = webView
    renderer.render(.message("x", "y"))
    var ready = false
    let deadline = Date().addingTimeInterval(8)
    while !ready, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ready = ((try? await webView.evaluateJavaScript("document.getElementById('root').children.length > 0")) as? Bool) ?? false
    }
    let files = (ProcessInfo.processInfo.environment["AGENTIDEA_PERF_FILES"] ?? "").split(separator: ":").map(String.init)
    for file in files {
        let url = URL(fileURLWithPath: file)
        guard case .text(let text, _, let lines) = TextFileLoader.load(url, fileManager: .default) else { continue }
        let language = Language.forFile(named: url.lastPathComponent).highlightID
        for wrap in [false, true] {
            let jsMs = Locked<Int>(-1)
            renderer.onRendered = { _, ms in jsMs.value = ms }
            let t0 = ProcessInfo.processInfo.systemUptime
            renderer.render(RenderPayload(.code(path: url.path, text: text, language: language), wrap: wrap))
            while jsMs.value < 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
            let t1 = ProcessInfo.processInfo.systemUptime
            let layout = try await webView.evaluateJavaScript("(function(){ const t = performance.now(); document.body.offsetHeight; return Math.round(performance.now() - t); })()")
            print(String(format: "RENDER PROBE %@ (%d lines, wrap=%d): js %d ms, round trip %.0f ms, forced layout %@ ms", url.lastPathComponent, lines, wrap ? 1 : 0, jsMs.value, (t1 - t0) * 1000, String(describing: layout ?? "?")))
        }
    }
}
