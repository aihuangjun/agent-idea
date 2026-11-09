import Core
import Foundation
import TestSupport
import Testing

/// 造一条 `git grep -n --column -z` 的记录。
private func record(_ path: String, _ line: Int, _ column: Int, _ text: String) -> Data {
    var data = Data(path.utf8)
    data.append(0)
    data.append(contentsOf: Array("\(line)".utf8) + [0] + Array("\(column)".utf8) + [0])
    data.append(contentsOf: Array(text.utf8) + [10])
    return data
}

private func matcher(_ text: String, caseSensitive: Bool = false, wholeWords: Bool = false, isRegex: Bool = false) throws -> TextSearchMatcher {
    try TextSearchMatcher(TextSearchQuery(text: text, caseSensitive: caseSensitive, wholeWords: wholeWords, isRegex: isRegex))
}

@Test func queryBecomesGitGrepArguments() {
    let plain = TextSearchQuery(text: "-foo bar")
    #expect(plain.gitGrepArguments() == ["-c", "grep.fullName=false", "-c", "grep.fallbackToNoIndex=false", "grep", "--untracked", "-I", "-n", "--column", "-z", "--no-color", "-i", "-F", "-e", "-foo bar", "--"],
            "默认不区分大小写、纯文本；查询用 -e 传，以 - 开头也不会被当成选项")
    let options = TextSearchQuery(text: "fo+", caseSensitive: true, wholeWords: true, isRegex: true, fileMask: "*.swift, Sources/**/*.md ,!*Tests.swift, ")
    #expect(options.gitGrepArguments() == ["-c", "grep.fullName=false", "-c", "grep.fallbackToNoIndex=false", "grep", "--untracked", "-I", "-n", "--column", "-z", "--no-color", "-w", "-P", "-e", "fo+", "--",
                                           ":(glob,icase)**/*.swift", ":(glob,icase)Sources/**/*.md", ":(glob,icase,exclude)**/*Tests.swift"])
    #expect(options.gitGrepArguments(perl: false).contains("-E"), "没有 PCRE 时退回 ERE")
    #expect(!options.gitGrepArguments(perl: false).contains("-P"))
}

@Test func fileMaskMatchesNamesOrPaths() {
    let query = TextSearchQuery(text: "x", fileMask: "*.swift, !*Tests.swift")
    #expect(query.matchesMask("Sources/Core/A.swift"))
    #expect(query.matchesMask("A.SWIFT"), "不分大小写")
    #expect(!query.matchesMask("Tests/ATests.swift"))
    #expect(!query.matchesMask("README.md"))
    let paths = TextSearchQuery(text: "x", fileMask: "Sources/**/*.md")
    #expect(paths.matchesMask("Sources/a.md"))
    #expect(paths.matchesMask("Sources/x/y/a.md"))
    #expect(!paths.matchesMask("Docs/a.md"))
    #expect(TextSearchQuery(text: "x").matchesMask("anything/at/all"), "没有掩码就全收")
    #expect(TextSearchQuery(text: "x", fileMask: "!*.min.js").matchesMask("a.js"), "只有排除的：其余都收")
    #expect(!TextSearchQuery(text: "x", fileMask: "!*.min.js").matchesMask("dist/a.min.js"))
}

@Test func matcherFindsEveryHitInALineInUTF16() throws {
    #expect(try matcher("foo").ranges(in: "foo Foo FOO") == [0..<3, 4..<7, 8..<11], "默认不区分大小写")
    #expect(try matcher("foo", caseSensitive: true).ranges(in: "foo Foo FOO") == [0..<3])
    // emoji 占两个 UTF-16 单元、一个字素：位置要按 UTF-16 算，CodeMirror 的 ch 就是这个口径
    #expect(try matcher("x").ranges(in: "😀x中x") == [2..<3, 4..<5])
    #expect(try matcher("a.b").ranges(in: "a.b axb") == [0..<3], "纯文本里的 . 不是通配")
    #expect(try matcher("a.b", isRegex: true).ranges(in: "a.b axb") == [0..<3, 4..<7])
    #expect(try matcher("a*", isRegex: true).ranges(in: "bab") == [1..<2], "空匹配不算")
    #expect(try matcher("ä").ranges(in: "Ä ä") == [0..<1, 2..<3], "非 ASCII 也折叠大小写")
}

@Test func wholeWordsUsesASCIIWordCharactersLikeGit() throws {
    let word = try matcher("foo", wholeWords: true)
    #expect(word.ranges(in: "foo food _foo foo_ (foo) foo") == [0..<3, 20..<23, 25..<28])
    // git -w 按字节判断，非 ASCII 字符不算词字符
    #expect(word.ranges(in: "中foo文") == [1..<4])
    #expect(try matcher("a|b", wholeWords: true, isRegex: true).ranges(in: "a ab b") == [0..<1, 5..<6], "正则整体加边界，不是只给第一个分支")
}

@Test func invalidRegexIsExplainedInPlainWords() {
    func message(_ pattern: String) -> String {
        do {
            _ = try matcher(pattern, isRegex: true)
            return ""
        } catch {
            return error.localizedDescription
        }
    }
    #expect(message("foo(") .contains("圆括号"))
    #expect(message("[abc").contains("方括号"))
    #expect(message("*foo").contains("前面没有可以重复的东西"))
    #expect(message("foo\\").contains("末尾多了一个"))
    #expect(message("foo(").contains("关掉「.*」"))
    #expect(message("fo+") == "", "合法的正则不报错")
    #expect((try? matcher("foo(")) != nil, "纯文本模式下括号不是语法")
}

@Test func gitGrepOutputParsesOddFileNamesAndConvertsByteColumns() throws {
    var data = Data()
    data.append(record("a:b c.txt", 1, 7, "hello foo"))
    data.append(record("a:b c.txt", 2, 8, "中文 foo foo"))
    data.append(record("子目录/文件.swift", 12, 3, "x\tfoo\r"))
    let result = GitGrepParser.parse(data, matcher: try matcher("foo"), limit: 100)
    #expect(result.files.map(\.path) == ["a:b c.txt", "子目录/文件.swift"], "文件名里的冒号、空格、中文原样保留")
    #expect(result.matchCount == 4)
    #expect(!result.isTruncated)
    let lines = result.files[0].lines
    #expect(lines.map(\.line) == [1, 2])
    #expect(lines[1].ranges == [3..<6, 7..<10], "同一行两处都标出来")
    #expect(lines[1].column == 3, "字节偏移 8（中文各占 3 个字节）→ UTF-16 的 3")
    #expect(lines[1].selectionLength == 3)
    #expect(result.files[1].lines[0].text == "x\tfoo", "CRLF 的 \\r 去掉")
    #expect(result.files[1].name == "文件.swift")
    #expect(result.files[1].directory == "子目录")
    #expect(result.files[0].directory == "")
}

@Test func parserFallsBackToGitColumnWhenItCannotFindTheHit() throws {
    // 正则方言不同、文件不是 UTF-8 时自己找不出来：位置用 git 给的字节列换算，范围留空、按 1 处算
    let data = record("a.txt", 3, 8, "中文 bar")
    let result = GitGrepParser.parse(data, matcher: try matcher("zzz"), limit: 10)
    #expect(result.files.first?.lines.first?.column == 3)
    #expect(result.files.first?.lines.first?.ranges == [])
    #expect(result.matchCount == 1)
    #expect(result.files.first?.lines.first?.selectionLength == 0)
}

@Test func byteColumnsBecomeUTF16Offsets() {
    let line = ArraySlice(Array("a中😀b".utf8))
    #expect(GitGrepParser.utf16Offset(ofByte: 0, in: line) == 0)
    #expect(GitGrepParser.utf16Offset(ofByte: 1, in: line) == 1)
    #expect(GitGrepParser.utf16Offset(ofByte: 4, in: line) == 2, "中 3 个字节、1 个 UTF-16 单元")
    #expect(GitGrepParser.utf16Offset(ofByte: 8, in: line) == 4, "😀 4 个字节、2 个 UTF-16 单元")
    #expect(GitGrepParser.utf16Offset(ofByte: 2, in: line) == 1, "落在多字节字符中间的按它的开头算")
    #expect(GitGrepParser.utf16Offset(ofByte: 99, in: line) == 5, "超出的夹到行尾")
}

@Test func parserStopsAtTheLimitAndDropsATruncatedTail() throws {
    var data = Data()
    for line in 1...5 { data.append(record("a.txt", line, 1, "foo foo")) }
    let result = GitGrepParser.parse(data, matcher: try matcher("foo"), limit: 5)
    #expect(result.matchCount == 4, "每行 2 处，上限 5：第三行放不下就不收，总数不超过上限")
    #expect(result.isTruncated)
    #expect(result.lineCount == 2)

    // 输出在一条记录中间断掉（被截断的管子）：残缺的那条不要
    var cut = record("a.txt", 1, 1, "foo")
    cut.append(Data("b.txt\u{0}2".utf8))
    let partial = GitGrepParser.parse(cut, matcher: try matcher("foo"), limit: 10)
    #expect(partial.files.map(\.path) == ["a.txt"])

    // 最后一行没有换行符也照收
    var noNewline = Data("c.txt\u{0}4\u{0}1\u{0}foo".utf8)
    noNewline.insert(contentsOf: record("a.txt", 1, 1, "foo"), at: 0)
    #expect(GitGrepParser.parse(noNewline, matcher: try matcher("foo"), limit: 10).files.map(\.path) == ["a.txt", "c.txt"])
}

@Test func collectorGroupsByFileAndCountsMatches() {
    var collector = TextSearchCollector(limit: 3)
    let added = [
        collector.add(path: "a", line: TextSearchLine(line: 1, text: "x", ranges: [0..<1], column: 0)),
        collector.add(path: "b", line: TextSearchLine(line: 1, text: "x", ranges: [], column: 0)),
        collector.add(path: "a", line: TextSearchLine(line: 9, text: "x", ranges: [0..<1], column: 0)),
        collector.add(path: "c", line: TextSearchLine(line: 1, text: "x", ranges: [0..<1], column: 0)),
    ]
    #expect(added == [true, true, true, false], "第四处到上限了")
    #expect(collector.result.files.map(\.path) == ["a", "b"])
    #expect(collector.result.files[0].lines.map(\.line) == [1, 9])
    #expect(collector.result.matchCount == 3)
    #expect(collector.result.isTruncated)

    // 第一行就超过上限也收下（不然什么都看不到）
    var tiny = TextSearchCollector(limit: 1)
    let first = tiny.add(path: "a", line: TextSearchLine(line: 1, text: "xx", ranges: [0..<1, 1..<2], column: 0))
    #expect(first)
    #expect(tiny.result.matchCount == 2)
}

@Test func snippetTrimsIndentationAndCentersLongLinesOnTheHit() {
    let indented = TextSearchSnippet.make(TextSearchLine(line: 1, text: "\t    let foo = 1  ", ranges: [9..<12], column: 9))
    #expect(indented.text == "let foo = 1")
    #expect(indented.ranges == [4..<7])

    let long = String(repeating: "a", count: 300) + "TARGET" + String(repeating: "b", count: 300)
    let snippet = TextSearchSnippet.make(TextSearchLine(line: 1, text: long, ranges: [300..<306], column: 300), maxLength: 100, leadingContext: 20)
    #expect(snippet.text.hasPrefix("…"))
    #expect(snippet.text.hasSuffix("…"))
    #expect(snippet.text.utf16.count == 102)
    let start = snippet.ranges[0].lowerBound
    let hit = (snippet.text as NSString).substring(with: NSRange(location: start, length: 6))
    #expect(hit == "TARGET", "命中在窗口里，范围跟着平移")
    #expect(start == 21, "命中前面留 20 个字符的上下文")

    // 命中靠近行尾：窗口贴着行尾，不留空
    let tail = TextSearchSnippet.make(TextSearchLine(line: 1, text: String(repeating: "a", count: 300) + "END", ranges: [300..<303], column: 300), maxLength: 50)
    #expect(tail.text.hasSuffix("END"))
    #expect(tail.ranges.count == 1)

    // 不劈开代理对
    let emoji = String(repeating: "😀", count: 100)
    let cut = TextSearchSnippet.make(TextSearchLine(line: 1, text: emoji, ranges: [101..<103], column: 101), maxLength: 21, leadingContext: 5)
    #expect(!cut.text.contains("\u{FFFD}"))
}

@Test func scannerSearchesFilesOutsideGit() async throws {
    try await withTemporaryDirectory { root in
        try "one foo\nfoo foo\r\nnone\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "let foo = 1".write(to: root.appendingPathComponent("sub/b.swift"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 0x66, 0x6F, 0x6F]).write(to: root.appendingPathComponent("bin.dat"))
        try Data(repeating: 0x66, count: TextSearchScanner.fileSizeLimit + 1).write(to: root.appendingPathComponent("big.txt"))
        let query = TextSearchQuery(text: "foo")
        let files = ["a.txt", "sub/b.swift", "bin.dat", "big.txt"]
        let result = TextSearchScanner.search(files: files, root: root, query: query, matcher: try TextSearchMatcher(query), limit: 100)
        #expect(result.files.map(\.path) == ["a.txt", "sub/b.swift"], "二进制、超过 2MB 的跳过")
        #expect(result.files[0].lines.map(\.line) == [1, 2])
        #expect(result.files[0].lines[1].ranges == [0..<3, 4..<7])
        #expect(result.files[0].lines[1].text == "foo foo")
        #expect(result.matchCount == 4)

        let masked = TextSearchQuery(text: "foo", fileMask: "*.swift")
        #expect(TextSearchScanner.search(files: files, root: root, query: masked, matcher: try TextSearchMatcher(masked), limit: 100).files.map(\.path) == ["sub/b.swift"])
    }
}

@Test func grepToleratesNoMatchesAndRetriesWithoutPCRE() async throws {
    let runner = FakeCommandRunner { arguments, _ in
        if arguments.contains("-P") { return shellOutput("", status: 128, stderr: "fatal: cannot use Perl-compatible regexes when not compiled with USE_LIBPCRE") }
        return shellOutput("", status: 1)
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let query = TextSearchQuery(text: "fo+", isRegex: true)
    let result = try await git.grep(query, matcher: try TextSearchMatcher(query), in: URL(fileURLWithPath: "/p"), limit: 10)
    #expect(result.files.isEmpty, "退出码 1 = 没找到，不是错误")
    #expect(runner.calls.count == 2)
    #expect(runner.calls.last?.arguments.contains("-E") == true)
    #expect(runner.calls.last?.directory == "/p", "在项目根里跑")
}

@Test func grepReportsInvalidPatternsAndOtherFailures() async throws {
    let runner = FakeCommandRunner { arguments, _ in
        if arguments.contains("-P") { return shellOutput("", status: 128, stderr: "fatal: -e option, 'a(?<': unrecognized character after (?<") }
        if arguments.contains("needle") { return shellOutput("", status: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git") }
        return shellOutput("", status: 128, stderr: "fatal: unable to read tree")
    }
    let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner)
    let regex = TextSearchQuery(text: "a(?<", isRegex: true)
    // ICU 也不认这个，用纯文本的匹配器喂进去，模拟「ICU 认、PCRE 不认」的情形
    let literalMatcher = try TextSearchMatcher(TextSearchQuery(text: "a"))
    await #expect(throws: TextSearchError.invalidRegex("正则表达式有误：unrecognized character after (?<。要按普通文字查找，关掉「.*」（正则）。")) {
        _ = try await git.grep(regex, matcher: literalMatcher, in: URL(fileURLWithPath: "/p"), limit: 10)
    }
    let plain = TextSearchQuery(text: "a")
    await #expect(throws: TextSearchError.failed("git grep 出错了：fatal: unable to read tree")) {
        _ = try await git.grep(plain, matcher: literalMatcher, in: URL(fileURLWithPath: "/p"), limit: 10)
    }
    let outside = TextSearchQuery(text: "needle")
    await #expect(throws: TextSearchError.notARepository, "调用方据此退回逐个读文件") {
        _ = try await git.grep(outside, matcher: literalMatcher, in: URL(fileURLWithPath: "/p"), limit: 10)
    }
}

/// 真跑系统 git：未跟踪的文件能搜到、被 .gitignore 忽略的与二进制搜不到；项目是仓库子目录时只搜子目录、路径相对子目录。
@Test func realGitGrepSearchesUntrackedButNotIgnoredFiles() async throws {
    guard let found = GitClient.locate() else { return }
    try await withTemporaryDirectory { directory in
        let shell = ShellCommand()
        let environment = ["GIT_CONFIG_NOSYSTEM": "1", "HOME": directory.path, "PATH": "/usr/bin:/bin"]
        func run(_ args: [String]) async throws {
            _ = try await shell.runChecked(executable: found.executable, arguments: args, currentDirectory: directory, environment: environment)
        }
        func write(_ text: String, _ path: String) throws {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try await run(["init", "-q", "-b", "main"])
        try write("*.log\nbuild/\n", ".gitignore")
        try write("let needle = 1\n", "tracked.swift")
        try await run(["add", "."])
        try write("Ä needle ä needle\n", "new file:1.txt")
        try write("needle\n", "ignored.log")
        try write("needle\n", "build/out.txt")
        try write("needle\n", "app/inner.swift")
        try Data([0, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: directory.appendingPathComponent("blob.bin"))

        let git = GitClient(executable: found.executable)
        let query = TextSearchQuery(text: "needle")
        let matcher = try TextSearchMatcher(query)
        let result = try await git.grep(query, matcher: matcher, in: directory, limit: 100)
        #expect(Set(result.files.map(\.path)) == ["app/inner.swift", "new file:1.txt", "tracked.swift"])
        let untracked = try #require(result.files.first { $0.path == "new file:1.txt" })
        #expect(untracked.lines.first?.ranges == [2..<8, 11..<17])
        #expect(untracked.lines.first?.column == 2)

        // UTF-8 环境下 -i 能折叠非 ASCII
        let umlaut = TextSearchQuery(text: "ä")
        #expect(try await git.grep(umlaut, matcher: try TextSearchMatcher(umlaut), in: directory, limit: 100).matchCount == 2)

        let sub = try await git.grep(query, matcher: matcher, in: directory.appendingPathComponent("app"), limit: 100)
        #expect(sub.files.map(\.path) == ["inner.swift"])
        // 用户配了 grep.fullName=true：路径仍要相对项目根（子目录），否则打开结果拼错路径
        try await run(["config", "grep.fullName", "true"])
        let fullName = try await git.grep(query, matcher: matcher, in: directory.appendingPathComponent("app"), limit: 100)
        #expect(fullName.files.map(\.path) == ["inner.swift"])

        // 仓库外的目录：用户配了 grep.fallbackToNoIndex=true 也要认出「不在仓库里」（否则与 --untracked 冲突报错）
        // （GitClient 用的是用户自己的 HOME，改不了它的全局配置；在参数前面再垫一个 -c 模拟，后出现的 -c 说了算）
        try await withTemporaryDirectory { outside in
            let output = try await shell.run(executable: found.executable, arguments: ["-c", "grep.fallbackToNoIndex=true"] + query.gitGrepArguments(),
                                             currentDirectory: outside, environment: environment.merging(["LC_ALL": "en_US.UTF-8"]) { $1 })
            #expect(output.standardError.contains("not a git repository"), "\(output.standardError)")
            await #expect(throws: TextSearchError.notARepository) {
                _ = try await git.grep(query, matcher: matcher, in: outside, limit: 100)
            }
        }

        let none = TextSearchQuery(text: "no-such-text")
        #expect(try await git.grep(none, matcher: try TextSearchMatcher(none), in: directory, limit: 100).files.isEmpty)

        let masked = TextSearchQuery(text: "needle", fileMask: "*.swift, !app/**")
        #expect(try await git.grep(masked, matcher: matcher, in: directory, limit: 100).files.map(\.path) == ["tracked.swift"])
        // 只有排除的掩码：其余整棵树照搜（git 2.13 起只有负 pathspec 时隐含「全部」）
        let excludeOnly = TextSearchQuery(text: "needle", fileMask: "!*.swift")
        #expect(try await git.grep(excludeOnly, matcher: matcher, in: directory, limit: 100).files.map(\.path) == ["new file:1.txt"])
        let excludeOnlySub = TextSearchQuery(text: "needle", fileMask: "!tracked.swift")
        #expect(Set(try await git.grep(excludeOnlySub, matcher: matcher, in: directory, limit: 100).files.map(\.path)) == ["app/inner.swift", "new file:1.txt"])
    }
}

@Test func selectionPrefillsOnlySingleLineText() {
    #expect(TextSearchQuery.prefill(fromSelection: "renderActiveTab", isRegex: false) == "renderActiveTab")
    #expect(TextSearchQuery.prefill(fromSelection: " a b ", isRegex: false) == " a b ", "原样保留，空格也是要找的")
    #expect(TextSearchQuery.prefill(fromSelection: "a.b(c)", isRegex: true) == "a\\.b\\(c\\)", "正则模式下转义成字面量")
    #expect(TextSearchQuery.prefill(fromSelection: "a\nb", isRegex: false) == nil, "多行不要")
    #expect(TextSearchQuery.prefill(fromSelection: "   ", isRegex: false) == nil)
    #expect(TextSearchQuery.prefill(fromSelection: "", isRegex: false) == nil)
    #expect(TextSearchQuery.prefill(fromSelection: nil, isRegex: false) == nil)
    #expect(TextSearchQuery.prefill(fromSelection: String(repeating: "x", count: 201), isRegex: false) == nil, "太长的不要")
}

@Test func scannerSkipsHiddenAndDependencyDirectories() {
    #expect(TextSearchScanner.skipsDirectory(".build"))
    #expect(TextSearchScanner.skipsDirectory("sub/.venv"))
    #expect(TextSearchScanner.skipsDirectory("web/node_modules"))
    #expect(!TextSearchScanner.skipsDirectory("Sources"))
    #expect(!TextSearchScanner.skipsDirectory("a.b/c"))
}
