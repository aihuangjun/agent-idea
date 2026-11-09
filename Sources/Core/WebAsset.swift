import Foundation

/// 渲染页按需读取的随包资源（tree-sitter 的 WASM 运行时、语法包与着色查询）。
///
/// 渲染页是 `loadFileURL` 加载的 file:// 页面，WebKit 不许它 `fetch` / XHR 本地文件，所以这些资源走宿主注册的自定义协议
/// `agentidea-asset://web/<相对 web 目录的路径>`。只放行 web 目录里白名单扩展名的文件，`..` 与符号链接越界一律拒绝。
public enum WebAsset {
    public static let scheme = "agentidea-asset"
    public static let host = "web"
    /// 只有这几种需要按需取；脚本与样式仍由页面自己用 <script> / <link> 从 file:// 加载。
    public static let allowedExtensions: Set<String> = ["wasm", "scm"]

    /// 请求地址 → web 目录里的文件。协议 / 主机不对、扩展名不在白名单、解析符号链接后跑出 web 目录，都回 nil。
    public static func fileURL(for url: URL, within root: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let relative = url.path
        guard !relative.isEmpty, relative != "/" else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else { return nil }
        guard allowedExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        return file
    }

    /// 响应的 Content-Type。`application/wasm` 让页面能用 `WebAssembly.instantiateStreaming`。
    public static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "wasm": return "application/wasm"
        case "scm": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
