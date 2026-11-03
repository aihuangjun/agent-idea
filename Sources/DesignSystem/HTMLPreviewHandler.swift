import Core
import Foundation
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// 独立 HTML WebView 的只读资源入口。没有编辑桥，也不授予 file:// 读取权限。
@MainActor
final class HTMLPreviewHandler: NSObject, WKURLSchemeHandler {
    var documentURL: URL?
    var resourceDirectory: URL?
    var document = Data()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let directory = resourceDirectory,
              let file = HTMLPreviewDocument.fileURL(for: url, within: directory) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission))
            return
        }
        let isDocument = url.path == documentURL?.path
        let draft = document
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                let data = isDocument ? draft : try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file) }.value
                guard !Task.isCancelled else { return }
                let mime = isDocument ? "text/html" : UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": mime + (isDocument ? "; charset=utf-8" : ""),
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-store"
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
