import Core
import Foundation
import Testing

// MARK: - 脚本 → 命令

@Test func pep723ScriptBlockIsRecognizedOnlyWhenWellFormed() {
    let pep723 = "# /// script\n# requires-python = \">=3.10\"\n# dependencies = [\"requests\"]\n#\n# ///\nimport requests\n"
    #expect(ScriptRunner.hasInlineScriptMetadata(pep723))
    #expect(ScriptRunner.hasInlineScriptMetadata(pep723.replacingOccurrences(of: "\n", with: "\r\n")))
    #expect(ScriptRunner.hasInlineScriptMetadata("#!/usr/bin/env -S uv run\n" + pep723), "shebang 在前面也算")
    #expect(ScriptRunner.hasInlineScriptMetadata("# /// script\n# ///\n"), "空块也是声明")
    #expect(!ScriptRunner.hasInlineScriptMetadata("import os\nprint(1)\n"))
    #expect(!ScriptRunner.hasInlineScriptMetadata("# /// script\n# dependencies = []\n"), "没闭合")
    #expect(!ScriptRunner.hasInlineScriptMetadata("# /// script\nimport os\n# ///\n"), "中间夹了代码")
    #expect(!ScriptRunner.hasInlineScriptMetadata("# /// pyproject\n# ///\n"), "别的类型不算")
    #expect(!ScriptRunner.hasInlineScriptMetadata("    # /// script\n    # ///\n"), "要顶格")
    #expect(!ScriptRunner.hasInlineScriptMetadata("#/// script\n#///\n"))
}

@Test func pythonScriptsPickUvOrPython3FromTheLoginPath() {
    let script = URL(fileURLWithPath: "/proj/tools/my job.py")
    let pep723 = "# /// script\n# dependencies = []\n# ///\nprint(1)\n"
    let environment = ["PATH": "/custom/bin:/usr/bin:/bin", "HOME": "/Users/me"]
    // uv 只装在 ~/.local/bin（PATH 里没有它，常见：那一行只写在 .zshrc 里）
    let present: Set<String> = ["/Users/me/.local/bin/uv", "/usr/bin/python3", "/opt/homebrew/bin/python3"]
    let exists: (String) -> Bool = { present.contains($0) }

    let uv = ScriptRunner.resolve(script: script, source: pep723, isExecutable: false, environment: environment, isExecutableFile: exists)
    #expect(uv.command?.executable.path == "/Users/me/.local/bin/uv")
    #expect(uv.command?.arguments == ["run", "--script", "/proj/tools/my job.py"])
    #expect(uv.command?.workingDirectory.path == "/proj/tools")
    #expect(uv.command?.display == "uv run --script my job.py")

    // 没声明：python3；/usr/bin 的系统占位版本排在最后，Homebrew 的先用上
    let plain = ScriptRunner.resolve(script: script, source: "print(1)", isExecutable: false, environment: environment, isExecutableFile: exists)
    guard case .ready(let python) = plain else { Issue.record("应当能跑：\(plain)"); return }
    #expect(python.executable.path == "/opt/homebrew/bin/python3")
    #expect(python.arguments == ["/proj/tools/my job.py"])
    #expect(python.display == "python3 my job.py")
    // 只有系统那个时也用它
    let onlySystem = ScriptRunner.resolve(script: script, source: "", isExecutable: false, environment: environment,
                                          isExecutableFile: { $0 == "/usr/bin/python3" })
    #expect((onlySystem.command?.executable.path) == "/usr/bin/python3")
    // PATH 里排前面的赢
    let custom = ScriptRunner.resolve(script: script, source: pep723, isExecutable: false, environment: environment,
                                      isExecutableFile: { $0 == "/custom/bin/uv" || $0 == "/Users/me/.local/bin/uv" })
    #expect((custom.command?.executable.path) == "/custom/bin/uv")

    // 找不到：说清楚缺什么，不起进程
    let missing = ScriptRunner.resolve(script: script, source: pep723, isExecutable: false, environment: environment, isExecutableFile: { _ in false })
    guard case .missing(let tool, let message) = missing else { Issue.record("应当缺 uv：\(missing)"); return }
    #expect(tool == "uv")
    #expect(message.contains("# /// script") && message.contains("my job.py"))
    if case .missing(let tool, _) = ScriptRunner.resolve(script: script, source: "", isExecutable: false, environment: environment, isExecutableFile: { _ in false }) {
        #expect(tool == "python3")
    } else {
        Issue.record("应当缺 python3")
    }
}

@Test func shellScriptsRunDirectlyWhenExecutableElseThroughTheirShell() {
    let environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"]
    let exists: (String) -> Bool = { ["/bin/bash", "/bin/zsh"].contains($0) }
    let deploy = URL(fileURLWithPath: "/proj/deploy.sh")
    let direct = ScriptRunner.resolve(script: deploy, source: "", isExecutable: true, environment: environment, isExecutableFile: exists).command
    #expect(direct?.executable == deploy && direct?.arguments == [] && direct?.display == "./deploy.sh")
    #expect(direct?.workingDirectory.path == "/proj")
    #expect((ScriptRunner.resolve(script: deploy, source: "", isExecutable: false, environment: environment, isExecutableFile: exists).command?.display) == "bash deploy.sh")
    let zsh = URL(fileURLWithPath: "/proj/x.zsh")
    #expect((ScriptRunner.resolve(script: zsh, source: "", isExecutable: false, environment: environment, isExecutableFile: exists).command?.executable.path) == "/bin/zsh")
    if case .missing(let tool, _) = ScriptRunner.resolve(script: URL(fileURLWithPath: "/proj/a.fish"), source: "", isExecutable: false,
                                                         environment: environment, isExecutableFile: exists) {
        #expect(tool == "fish")
    } else {
        Issue.record("没装 fish 应当报缺")
    }

    #expect(ScriptRunner.kind(forFileNamed: "a.py") == .python)
    #expect(ScriptRunner.kind(forFileNamed: "a.sh") == .shell)
    #expect(ScriptRunner.kind(forFileNamed: "a.swift") == nil)

}

private extension ScriptRunner.Resolution {
    var command: ScriptCommand? {
        if case .ready(let command) = self { return command }
        return nil
    }
}

@Test func pythonScriptsInsideAProjectUseTheProjectEnvironment() {
    let environment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"]
    let tools: Set<String> = ["/Users/me/.local/bin/uv", "/usr/bin/python3", "/work/plain/.venv/bin/python"]
    // laya 那种：pyproject.toml + uv.lock 在脚本的上一级，脚本没有 # /// script 声明
    let files: Set<String> = ["/work/laya/pyproject.toml", "/work/laya/uv.lock", "/work/plain/.venv/bin/python", "/work/half/pyproject.toml"]
    func resolve(_ path: String, _ source: String = "print(1)") -> ScriptRunner.Resolution {
        ScriptRunner.resolve(script: URL(fileURLWithPath: path), source: source, isExecutable: false, environment: environment,
                             isExecutableFile: { tools.contains($0) }, fileExists: { files.contains($0) })
    }

    let inProject = resolve("/work/laya/examples/01_noul.py").command
    #expect(inProject?.executable.path == "/Users/me/.local/bin/uv")
    #expect(inProject?.arguments == ["run", "/work/laya/examples/01_noul.py"])
    #expect(inProject?.workingDirectory.path == "/work/laya/examples", "uv 从工作目录往上自己找到项目")
    #expect(inProject?.display == "uv run 01_noul.py")
    // 声明块优先：项目里带 # /// script 的照样按声明跑（uv 本身也是这个规矩）
    #expect(resolve("/work/laya/x.py", "# /// script\n# ///\n").command?.arguments == ["run", "--script", "/work/laya/x.py"])
    // 只有 .venv（不是 uv 管的）：用它的解释器
    let venv = resolve("/work/plain/a.py").command
    #expect(venv?.executable.path == "/work/plain/.venv/bin/python")
    #expect(venv?.display == ".venv/bin/python a.py")
    // 只有 pyproject.toml、没有 uv.lock：不当 uv 项目，退回 python3
    #expect(resolve("/work/half/a.py").command?.executable.path == "/usr/bin/python3")
    #expect(resolve("/elsewhere/a.py").command?.display == "python3 a.py")

    // uv 项目但没装 uv：说清楚为什么要 uv
    let missing = ScriptRunner.resolve(script: URL(fileURLWithPath: "/work/laya/01_noul.py"), source: "", isExecutable: false,
                                       environment: environment, isExecutableFile: { $0 == "/usr/bin/python3" }, fileExists: { files.contains($0) })
    if case .missing(let tool, let message) = missing {
        #expect(tool == "uv" && message.contains("uv.lock"))
    } else {
        Issue.record("应当报缺 uv：\(missing)")
    }
}
