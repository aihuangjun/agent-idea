import Foundation

/// 「运行」一个脚本要起的进程：直接起可执行文件、参数逐个传，不拼 shell 字符串（省掉引号问题）。
public struct ScriptCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    /// 脚本所在的目录，相对路径照在终端里那样解析。
    public let workingDirectory: URL
    /// 给人看的那条命令：标题条与输出第一行，脚本只写文件名（`uv run --script 01_noul.py`）。
    public let display: String

    public init(executable: URL, arguments: [String], workingDirectory: URL, display: String) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.display = display
    }

    /// 同一条命令在 shell 里的写法（「在终端中运行」用）。
    public var shellLine: String {
        ([executable.path] + arguments).map(TerminalLauncher.shellQuote).joined(separator: " ")
    }
}

/// 脚本 → 命令。Python 按顺序：带 PEP 723 `# /// script` 声明的交给 `uv run --script`（uv 按声明备好 Python 版本与依赖）；
/// 在 uv 项目里（往上有 pyproject.toml + uv.lock）的 `uv run`，用项目的环境；往上有 `.venv` 的用它的解释器；其余 `python3`。shell 脚本：有执行位直接跑，没有就按扩展名交给 bash / zsh / fish。
///
/// GUI 应用不继承 shell 的 PATH，所以可执行文件按登录 shell 的 PATH（`LoginShellEnvironment`）找，
/// 再补几处常见的安装位置——uv 的安装脚本放在 `~/.local/bin`，那一行 PATH 往往只写在 `.zshrc` 里。
public enum ScriptRunner {
    public enum Kind: Equatable, Sendable {
        case shell
        case python
    }

    public static func kind(forFileNamed name: String) -> Kind? {
        switch Language.forFile(named: name).name {
        case "Shell": return .shell
        case "Python": return .python
        default: return nil
        }
    }

    public enum Resolution: Equatable, Sendable {
        case ready(ScriptCommand)
        /// 找不到要用的程序：`message` 原样显示给人看。
        case missing(tool: String, message: String)
    }

    /// - Parameters:
    ///   - source: 脚本的内容（只有 Python 要看：有没有 `script` 声明块）。
    ///   - isExecutable: 脚本自己有没有执行位（只有 shell 脚本看）。
    ///   - isExecutableFile: 替身用，默认问文件系统。
    public static func resolve(
        script: URL,
        source: String,
        isExecutable: Bool,
        environment: [String: String],
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Resolution {
        let directory = script.deletingLastPathComponent()
        let name = script.lastPathComponent
        func locate(_ tool: String) -> URL? {
            searchDirectories(for: tool, environment: environment)
                .map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
                .first { isExecutableFile($0.path) }
        }

        switch kind(forFileNamed: name) {
        case .python:
            if hasInlineScriptMetadata(source) {
                guard let uv = locate("uv") else {
                    return .missing(tool: "uv", message: "找不到 uv：\(name) 开头有 # /// script 声明，要用 uv 运行。"
                        + "安装见 https://docs.astral.sh/uv/ ，装好后重新运行。")
                }
                return .ready(ScriptCommand(executable: uv, arguments: ["run", "--script", script.path],
                                            workingDirectory: directory, display: "uv run --script \(name)"))
            }
            // 脚本在一个 uv 项目里（README 里写的是 `uv run xx.py`）：依赖装在项目的 .venv 里，系统 python3 找不到它们
            if let project = enclosingDirectory(of: script, containingAll: ["pyproject.toml", "uv.lock"], fileExists: fileExists) {
                guard let uv = locate("uv") else {
                    return .missing(tool: "uv", message: "找不到 uv：\(name) 在 uv 项目 \(project.lastPathComponent) 里（有 uv.lock），要用 uv 运行。"
                        + "安装见 https://docs.astral.sh/uv/ ，装好后重新运行。")
                }
                return .ready(ScriptCommand(executable: uv, arguments: ["run", script.path],
                                            workingDirectory: directory, display: "uv run \(name)"))
            }
            // 不是 uv 管的，但旁边（或上级）建过虚拟环境：用它的解释器，照 IDEA 用项目解释器的习惯
            if let venv = enclosingDirectory(of: script, containingAll: [".venv/bin/python"], fileExists: fileExists) {
                let python = venv.appendingPathComponent(".venv/bin/python")
                if isExecutableFile(python.path) {
                    return .ready(ScriptCommand(executable: python, arguments: [script.path], workingDirectory: directory,
                                                display: ".venv/bin/python \(name)"))
                }
            }
            guard let python = locate("python3") else {
                return .missing(tool: "python3", message: "找不到 python3。装一个 Python 3（比如 brew install python）后重新运行。")
            }
            return .ready(ScriptCommand(executable: python, arguments: [script.path], workingDirectory: directory, display: "python3 \(name)"))
        case .shell, nil:
            if isExecutable {
                return .ready(ScriptCommand(executable: script, arguments: [], workingDirectory: directory, display: "./\(name)"))
            }
            let shell = TerminalLauncher.interpreter(for: script)
            guard let interpreter = locate(shell) else {
                return .missing(tool: shell, message: "找不到 \(shell)，运行不了 \(name)。")
            }
            return .ready(ScriptCommand(executable: interpreter, arguments: [script.path], workingDirectory: directory, display: "\(shell) \(name)"))
        }
    }

    /// 从脚本所在目录往上找第一个同时有这些文件的目录。到家目录或根目录为止，不出家目录往上找
    /// （`/Users` 下面不会有项目，免得撞上别人的东西）。
    static func enclosingDirectory(of script: URL, containingAll names: [String], fileExists: (String) -> Bool) -> URL? {
        let home = NSHomeDirectory()
        var directory = script.deletingLastPathComponent().standardizedFileURL
        while true {
            if names.allSatisfy({ fileExists(directory.appendingPathComponent($0).path) }) { return directory }
            let path = directory.path
            if path == "/" || path == home { return nil }
            directory = directory.deletingLastPathComponent()
        }
    }

    /// 按什么顺序找：登录 shell 的 PATH，再补常见的安装位置。找 python3 时 `/usr/bin` 排最后：
    /// 那是系统的占位版本，没装 CLT 的机器上一跑就弹「要安装命令行开发者工具吗」。
    static func searchDirectories(for tool: String, environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        directories = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
        if tool == "python3", let system = directories.firstIndex(of: "/usr/bin") {
            directories.append(directories.remove(at: system))
        }
        return directories
    }

    /// 子进程的环境：登录 shell 的那一份，再加两条。
    /// - `PYTHONUNBUFFERED`：输出不是终端时 Python 默认整块缓冲，不设的话 `print` 要等进程退出才一起冒出来，像是卡住了
    ///   （`uv run` 会把环境原样交给它起的 python）。
    /// - `PYTHONIOENCODING`：GUI 应用的环境里常常没有 `LANG`，Python 会退回 ASCII，打印中文直接 UnicodeEncodeError。
    public static func environment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        return environment
    }

    /// 源码里有没有 PEP 723 的 `script` 内联元数据块：
    ///
    ///     # /// script
    ///     # dependencies = ["requests"]
    ///     # ///
    ///
    /// 照 PEP 的参考正则：开头一行恰好是 `# /// script`，中间每行是 `#` 或 `# …`，以恰好 `# ///` 的一行收尾。
    /// 中间夹了一行不是注释的就不算（块没闭合）。
    public static func hasInlineScriptMetadata(_ source: String) -> Bool {
        var inBlock = false
        // `\r\n` 在 Swift 里是一个 Character，按 "\n" 切不开
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if !inBlock {
                if line == "# /// script" { inBlock = true }
            } else if line == "# ///" {
                return true
            } else if !(line == "#" || line.hasPrefix("# ")) {
                inBlock = false
            }
        }
        return false
    }
}
