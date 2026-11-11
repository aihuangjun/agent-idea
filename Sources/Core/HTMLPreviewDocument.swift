import Foundation

/// HTML 预览的资源定位与读取范围。注入 base 保留相对路径，不改正文、样式或脚本。
public enum HTMLPreviewDocument {
    public static let resourceScheme = "agentidea-html"

    /// 项目目录作为站点根目录：/assets/a.css 与 ../assets/a.css 都按网站路径解析。
    /// 地址不包含磁盘绝对路径，也不给运行脚本的页面 file:// 读取权限。
    public static func resourceURL(for file: URL, within directory: URL) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = file.resolvingSymlinksInPath().standardizedFileURL
        guard contains(file, within: root) else { return nil }
        var components = URLComponents()
        components.scheme = resourceScheme
        components.host = "preview"
        components.path = "/" + file.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1)
        return components.url
    }

    public static func fileURL(for resource: URL, within directory: URL) -> URL? {
        guard resource.scheme == resourceScheme, resource.host == "preview",
              resource.user == nil, resource.password == nil, resource.port == nil else { return nil }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var file = root.appendingPathComponent(String(resource.path.drop(while: { $0 == "/" })))
            .resolvingSymlinksInPath().standardizedFileURL
        guard contains(file, within: root) else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file = file.appendingPathComponent("index.html").resolvingSymlinksInPath().standardizedFileURL
        }
        return contains(file, within: root) ? file : nil
    }

    public static func resourceDirectory(for file: URL, in project: URL) -> URL {
        resourceURL(for: file, within: project) != nil ? project : file.deletingLastPathComponent()
    }

    private static func contains(_ file: URL, within root: URL) -> Bool {
        file.path == root.path || file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }

    public static func resolvingResources(in html: String, relativeTo file: URL) -> String {
        let escaped = file.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let base = "<base href=\"\(escaped)\">"
        // 跳过注释与原始文本元素；属性内的 > 也不代表标签结束。
        let pattern = #"<!--[\s\S]*?-->|<(script|style|textarea|title)\b(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>[\s\S]*?</\1\s*>|<(?:base|head)\b(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>|<!doctype\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return base + html }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var headEnd: String.Index?
        var doctypeEnd: String.Index?
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range]).lowercased()
            if tag.hasPrefix("<base") {
                let attributes = #"\s+([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#
                if let hrefRegex = try? NSRegularExpression(pattern: attributes, options: [.caseInsensitive]),
                   let href = hrefRegex.matches(in: String(html[range]), range: NSRange(location: 0, length: html[range].utf16.count)).first(where: {
                       guard let name = Range($0.range(at: 1), in: html[range]) else { return false }
                       return html[range][name].lowercased() == "href"
                   }) {
                    let originalTag = String(html[range])
                    let value = (2...4).compactMap { Range(href.range(at: $0), in: originalTag) }.first.map { String(originalTag[$0]) } ?? ""
                    if let resolved = URL(string: value.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: file)?.absoluteURL {
                        let resolvedHref = resolved.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                        let updatedTag = (originalTag as NSString).replacingCharacters(in: href.range, with: " href=\"\(resolvedHref)\"")
                        return html.replacingCharacters(in: range, with: updatedTag)
                    }
                }
            }
            if tag.hasPrefix("<head"), headEnd == nil { headEnd = range.upperBound }
            if tag.hasPrefix("<!doctype"), doctypeEnd == nil { doctypeEnd = range.upperBound }
        }
        var result = html
        result.insert(contentsOf: base, at: headEnd ?? doctypeEnd ?? html.startIndex)
        return result
    }
}
