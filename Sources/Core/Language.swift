import Foundation

/// 一个文件按什么语言高亮、在界面上叫什么。
///
/// `highlightID` 是 highlight.js 的语言名，`nil` 表示不高亮（纯文本）。
/// 这份表是**唯一事实来源**，前端不再自己按扩展名猜。
public struct Language: Equatable, Hashable, Sendable {
    public let name: String
    public let highlightID: String?

    public init(name: String, highlightID: String?) {
        self.name = name
        self.highlightID = highlightID
    }

    public static let plainText = Language(name: "Text", highlightID: nil)
    public static let markdown = Language(name: "Markdown", highlightID: "markdown")
    public static let json = Language(name: "JSON", highlightID: "json")
    public static let xml = Language(name: "XML", highlightID: "xml")

    // MARK: - 识别

    public static func forFile(named fileName: String) -> Language {
        let lower = fileName.lowercased()
        if let exact = byFileName[lower] { return exact }
        // `.gitignore`、`.env.local` 这种：没有传统意义的扩展名，整名或去掉后缀后再查。
        if lower.hasPrefix(".") {
            let stem = lower.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? lower
            if let dot = byFileName["." + stem] { return dot }
        }
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty { return plainText }
        return byExtension[ext] ?? Language(name: ext.uppercased(), highlightID: nil)
    }

    private static let byFileName: [String: Language] = [
        "dockerfile": Language(name: "Dockerfile", highlightID: "dockerfile"),
        "makefile": Language(name: "Makefile", highlightID: "makefile"),
        "cmakelists.txt": Language(name: "CMake", highlightID: "cmake"),
        "podfile": Language(name: "Ruby", highlightID: "ruby"),
        "gemfile": Language(name: "Ruby", highlightID: "ruby"),
        "rakefile": Language(name: "Ruby", highlightID: "ruby"),
        "package.resolved": json,
        ".gitignore": Language(name: "Ignore", highlightID: nil),
        ".gitattributes": Language(name: "Git", highlightID: nil),
        ".env": Language(name: "Env", highlightID: "ini"),
        ".editorconfig": Language(name: "INI", highlightID: "ini"),
        ".npmrc": Language(name: "INI", highlightID: "ini"),
        "license": plainText,
        "changelog": markdown,
        "readme": markdown,
    ]

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        func add(_ exts: [String], _ name: String, _ id: String?) {
            for ext in exts { map[ext] = Language(name: name, highlightID: id) }
        }
        add(["md", "markdown", "mdx"], "Markdown", "markdown")
        add(["json", "jsonc", "json5", "webmanifest", "ipynb"], "JSON", "json")
        add(["xml", "plist", "xib", "storyboard", "xsd", "xsl", "svg", "entitlements", "pom", "xcscheme", "xcworkspacedata", "pbxproj"], "XML", "xml")
        add(["html", "htm", "xhtml", "vue", "svelte", "jsp", "ejs"], "HTML", "xml")
        add(["swift"], "Swift", "swift")
        add(["js", "mjs", "cjs", "jsx"], "JavaScript", "javascript")
        add(["ts", "mts", "cts", "tsx"], "TypeScript", "typescript")
        add(["py", "pyi", "pyw"], "Python", "python")
        add(["java"], "Java", "java")
        add(["kt", "kts"], "Kotlin", "kotlin")
        add(["go"], "Go", "go")
        add(["rs"], "Rust", "rust")
        add(["c", "h"], "C", "c")
        add(["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino"], "C++", "cpp")
        add(["m"], "Objective-C", "objectivec")
        add(["mm"], "Objective-C++", "objectivec")
        add(["cs"], "C#", "csharp")
        add(["rb", "erb"], "Ruby", "ruby")
        add(["php"], "PHP", "php")
        add(["sh", "bash", "zsh", "fish", "command"], "Shell", "bash")
        add(["ps1", "psm1"], "PowerShell", "powershell")
        add(["yaml", "yml"], "YAML", "yaml")
        add(["toml"], "TOML", "ini")
        add(["ini", "cfg", "conf", "properties", "env"], "INI", "ini")
        add(["css"], "CSS", "css")
        add(["scss", "sass"], "SCSS", "scss")
        add(["less"], "Less", "less")
        add(["sql"], "SQL", "sql")
        add(["gradle", "groovy"], "Groovy", "groovy")
        add(["lua"], "Lua", "lua")
        add(["dart"], "Dart", "dart")
        add(["scala", "sbt"], "Scala", "scala")
        add(["r"], "R", "r")
        add(["pl", "pm"], "Perl", "perl")
        add(["graphql", "gql"], "GraphQL", "graphql")
        add(["proto"], "Protobuf", "protobuf")
        add(["diff", "patch"], "Diff", "diff")
        add(["dockerfile"], "Dockerfile", "dockerfile")
        add(["mk"], "Makefile", "makefile")
        add(["txt", "text", "log", "lock", "csv", "tsv"], "Text", nil)
        add(["vb"], "VB.NET", "vbnet")
        add(["wasm", "wat"], "WebAssembly", "wasm")
        add(["tf", "hcl"], "HCL", "ini")
        add(["nix"], "Nix", "nix")
        add(["ex", "exs"], "Elixir", "elixir")
        add(["erl"], "Erlang", "erlang")
        add(["hs"], "Haskell", "haskell")
        add(["clj", "cljs", "edn"], "Clojure", "clojure")
        add(["zig"], "Zig", "zig")
        return map
    }()
}

/// 按内容大类决定用什么方式展示。
public enum FileCategory: Equatable, Sendable {
    case markdown
    case code(Language)
    case image
    case pdf

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "heic", "heif", "avif",
    ]

    public static func forFile(named fileName: String) -> FileCategory {
        let ext = (fileName.lowercased() as NSString).pathExtension
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        let language = Language.forFile(named: fileName)
        if language == .markdown { return .markdown }
        return .code(language)
    }
}
