import Foundation

/// 「在终端中运行」：生成一个 `.command` 文件，交给系统用终端打开。
///
/// 不走 AppleScript（要申请自动化权限、还得看用户装的是哪个终端）；`.command` 文件默认就由终端打开并执行，
/// 我们只负责写好「进到脚本所在目录、运行它」这几行。
public enum TerminalLauncher {
    /// 能这么运行的文件：shell 脚本。
    public static func canRun(fileNamed name: String) -> Bool {
        Language.forFile(named: name).name == "Shell"
    }

    /// 没有执行位时用哪个解释器跑：按扩展名，`.zsh` 用 zsh、`.fish` 用 fish，其余 bash。
    public static func interpreter(for script: URL) -> String {
        switch script.pathExtension.lowercased() {
        case "zsh": return "zsh"
        case "fish": return "fish"
        default: return "bash"
        }
    }

    /// 包装脚本的内容。脚本有执行位就直接跑，没有就交给解释器；跑完停一下让人看得到输出。
    public static func commandScript(for script: URL, isExecutable: Bool) -> String {
        let directory = shellQuote(script.deletingLastPathComponent().path)
        let path = shellQuote(script.path)
        let run = isExecutable ? path : "\(interpreter(for: script)) \(path)"
        return """
        #!/bin/bash
        # Agent IDEA 生成：在终端里运行 \(script.lastPathComponent)
        cd \(directory) || exit 1
        echo "$ \(script.lastPathComponent)"
        \(run)
        status=$?
        echo
        echo "[进程已结束，退出码 $status]"
        exit $status

        """
    }

    /// 包装文件放哪：按脚本路径取个稳定的名字，同一个脚本反复运行（跨进程也）只留一个文件。
    /// 用 FNV-1a 而不是 `hashValue`：后者每次启动换随机种子，`~/.agentidea/run/` 会越堆越多。
    public static func commandFileURL(for script: URL, in directory: URL) -> URL {
        let stem = script.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(stem)-\(fnv1a(script.path)).command")
    }

    public static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    /// 写好包装文件（可执行）并返回它。
    public static func prepare(script: URL, in directory: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = commandFileURL(for: script, in: directory)
        let content = commandScript(for: script, isExecutable: fileManager.isExecutableFile(atPath: script.path))
        try content.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// 单引号包起来，内部的单引号用 `'\''` 接。
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
