import Core
import Foundation
import Testing
import TestSupport

@Test func lineEndingDetectionAndRestore() {
    #expect(LineEnding.detect(in: "a\r\nb\r\n") == .crlf)
    #expect(LineEnding.detect(in: "a\nb\n") == .lf)
    #expect(LineEnding.detect(in: "no newline") == .lf)
    #expect(LineEnding.detect(in: "") == .lf)
    #expect(LineEnding.crlf.apply(to: "a\nb\n") == "a\r\nb\r\n")
    #expect(LineEnding.lf.apply(to: "a\nb\n") == "a\nb\n")
    #expect(LineEnding.crlf.apply(to: "a\r\nb\n") == "a\r\nb\r\n", "已经是 CRLF 的不会变成 \\r\\r\\n")
    #expect(LineEnding.normalized("a\r\nb\n") == "a\nb\n")
}

@Test func savedBytesKeepEncodingAndLineEnding() {
    let crlf = TextFileSaver.data(for: "x\ny\n", encodingName: "UTF-8", original: "a\r\nb\r\n")
    #expect(String(decoding: crlf, as: UTF8.self) == "x\r\ny\r\n")
    // GB18030 读进来的中文写回去还是 GB18030，能被同一路径解回来
    let gb = TextFileSaver.data(for: "中文", encodingName: "GB18030", original: "")
    #expect(TextFileLoader.decode(gb) == .text("中文", encoding: "GB18030", lineCount: 1))
    // 不认识的编码名退回 UTF-8
    #expect(TextFileSaver.data(for: "é", encodingName: "???", original: "") == Data("é".utf8))
}

@Test func navigationHistoryBehavesLikeABrowser() {
    var history = NavigationHistory<String>(capacity: 4)
    #expect(!history.canGoBack && !history.canGoForward && history.current == nil)
    history.visit("a")
    history.visit("b")
    history.visit("b")   // 连续同一处只记一次
    history.visit("c")
    #expect(history.entries == ["a", "b", "c"])
    #expect(history.goBack() == "b")
    #expect(history.goBack() == "a")
    #expect(history.goBack() == nil)
    #expect(history.goForward() == "b")
    // 从中间出发去新地方：前进那一截作废
    history.visit("d")
    #expect(history.entries == ["a", "b", "d"] && !history.canGoForward)
    history.visit("e")
    history.visit("f")
    #expect(history.entries == ["b", "d", "e", "f"], "超过容量丢最早的")
    // 关掉 d：抹掉它，指针仍指向 f
    history.remove("d")
    #expect(history.entries == ["b", "e", "f"] && history.current == "f")
    // 抹掉当前项：指针退到前一项
    history.remove("f")
    #expect(history.current == "e" && history.canGoBack && !history.canGoForward)
    // 抹掉后两边相同的合并
    var merged = NavigationHistory<String>()
    merged.visit("x"); merged.visit("y"); merged.visit("x")
    merged.remove("y")
    #expect(merged.entries == ["x"] && merged.current == "x")
    merged.remove("x")
    #expect(merged.entries.isEmpty && merged.current == nil && !merged.canGoBack)
}

@Test func trashMovesItemsOutOfTheWay() throws {
    try withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("gone.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try Trash.move(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: (any Error).self) { try Trash.move(file) }
    }
}

@Test func terminalLauncherQuotesPathsAndPicksRunner() throws {
    #expect(TerminalLauncher.canRun(fileNamed: "deploy.sh"))
    #expect(TerminalLauncher.canRun(fileNamed: "x.command"))
    #expect(!TerminalLauncher.canRun(fileNamed: "main.py"))
    #expect(TerminalLauncher.shellQuote("it's") == "'it'\\''s'")

    #expect(TerminalLauncher.interpreter(for: URL(fileURLWithPath: "/a/b.zsh")) == "zsh")
    #expect(TerminalLauncher.interpreter(for: URL(fileURLWithPath: "/a/b.fish")) == "fish")
    #expect(TerminalLauncher.interpreter(for: URL(fileURLWithPath: "/a/b.sh")) == "bash")
    // 文件名跨进程稳定：FNV-1a 的固定值，不是随进程换种子的 hashValue
    #expect(TerminalLauncher.fnv1a("/tmp/x.sh") == TerminalLauncher.fnv1a("/tmp/x.sh"))
    #expect(TerminalLauncher.fnv1a("") == "33niihzj4ux45", "空串的 FNV-1a 偏移基准，换了算法这里会变")
    #expect(TerminalLauncher.commandFileURL(for: URL(fileURLWithPath: "/tmp/x.sh"), in: URL(fileURLWithPath: "/run")).lastPathComponent == "x-\(TerminalLauncher.fnv1a("/tmp/x.sh")).command")

    let script = URL(fileURLWithPath: "/tmp/my dir/it's.sh")
    let plain = TerminalLauncher.commandScript(for: script, isExecutable: false)
    #expect(plain.hasPrefix("#!/bin/bash\n"))
    #expect(plain.contains("cd '/tmp/my dir' || exit 1"))
    #expect(plain.contains("\nbash '/tmp/my dir/it'\\''s.sh'\n"))
    let executable = TerminalLauncher.commandScript(for: script, isExecutable: true)
    #expect(executable.contains("\n'/tmp/my dir/it'\\''s.sh'\n") && !executable.contains("bash '"))

    try withTemporaryDirectory { directory in
        let target = directory.appendingPathComponent("run.sh")
        try "echo hi".write(to: target, atomically: true, encoding: .utf8)
        let wrapper = try TerminalLauncher.prepare(script: target, in: directory.appendingPathComponent("run"))
        #expect(wrapper.pathExtension == "command")
        #expect(FileManager.default.isExecutableFile(atPath: wrapper.path))
        #expect(try String(contentsOf: wrapper, encoding: .utf8).contains("bash '\(target.path)'"))
        // 同一个脚本再准备一次：还是同一个文件
        #expect(try TerminalLauncher.prepare(script: target, in: directory.appendingPathComponent("run")) == wrapper)
    }
}
