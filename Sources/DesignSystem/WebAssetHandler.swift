import Core
import Foundation
@preconcurrency import WebKit

/// 渲染页的 `agentidea-asset:` 协议：按需把 web 目录里的 WASM 与查询文件交给页面（见 `Core/WebAsset`）。
///
/// 渲染页是 file:// 页面，origin 是 null，响应必须带 `Access-Control-Allow-Origin: *`，否则 fetch 被 CORS 拦下。
/// 读盘放后台（C++ 语法包 3MB 多）；任务被 WebKit 停掉之后不能再回调 WKURLSchemeTask。
@MainActor
final class WebAssetHandler: NSObject, WKURLSchemeHandler {
    private let root: URL?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(root: URL?) {
        self.root = root
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root, let file = WebAsset.fileURL(for: url, within: root) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file) }.value
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": WebAsset.mimeType(for: file),
                    "Content-Length": String(data.count),
                    "Access-Control-Allow-Origin": "*",
                ])!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
