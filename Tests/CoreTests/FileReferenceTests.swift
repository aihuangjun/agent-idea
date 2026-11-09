import Core
import Foundation
import Testing

@Test func referenceFormatsPathLineAndRange() {
    #expect(FileReference.format(path: "Sources/A.swift", lines: nil) == "Sources/A.swift")
    #expect(FileReference.format(path: "Sources/A.swift", lines: 12...12) == "Sources/A.swift:12")
    #expect(FileReference.format(path: "Sources/A.swift", lines: 12...20) == "Sources/A.swift:12-20")
}

@Test func selectionBecomesOneBasedLineRange() {
    // 光标：同一点
    #expect(FileReference.lineRange(fromLine: 11, fromColumn: 4, toLine: 11, toColumn: 4) == 12...12)
    // 行内选区
    #expect(FileReference.lineRange(fromLine: 11, fromColumn: 0, toLine: 11, toColumn: 9) == 12...12)
    // 跨行
    #expect(FileReference.lineRange(fromLine: 11, fromColumn: 2, toLine: 19, toColumn: 3) == 12...20)
    // 选到下一行行首（整行选）：那一行不算
    #expect(FileReference.lineRange(fromLine: 11, fromColumn: 0, toLine: 20, toColumn: 0) == 12...20)
    #expect(FileReference.lineRange(fromLine: 11, fromColumn: 0, toLine: 12, toColumn: 0) == 12...12)
    // 反着选（锚点在后）也一样
    #expect(FileReference.lineRange(fromLine: 19, fromColumn: 3, toLine: 11, toColumn: 2) == 12...20)
    #expect(FileReference.lineRange(fromLine: 0, fromColumn: 0, toLine: 0, toColumn: 0) == 1...1)
}

@Test func relativePathIsAgainstTheProjectRoot() {
    #expect(FileReference.relativePath(of: "/p/proj/Sources/A.swift", root: "/p/proj") == "Sources/A.swift")
    #expect(FileReference.relativePath(of: "/p/proj/Sources/A.swift", root: "/p/proj/") == "Sources/A.swift")
    #expect(FileReference.relativePath(of: "/p/proj", root: "/p/proj") == "")
    #expect(FileReference.relativePath(of: "/p/project2/A.swift", root: "/p/proj") == nil, "前缀相同的兄弟目录不算在根下")
    #expect(FileReference.relativePath(of: "/etc/hosts", root: "/p/proj") == nil)
}

@Test func goToLineInputAcceptsLineAndLineColumn() {
    #expect(FileReference.parseLineColumn("12") == SourceLocation(line: 12))
    #expect(FileReference.parseLineColumn(" 12:5 ") == SourceLocation(line: 12, column: 5))
    #expect(FileReference.parseLineColumn("12 : 5") == SourceLocation(line: 12, column: 5))
    #expect(FileReference.parseLineColumn("0") == SourceLocation(line: 1), "0 夹到第 1 行")
    #expect(FileReference.parseLineColumn("99999999999999999999999")?.line == Int.max, "太大的交给编辑器夹到末行")
    for invalid in ["", "abc", "12:", ":5", "-3", "1.5", "12:5:7", "１２"] {
        #expect(FileReference.parseLineColumn(invalid) == nil, "\(invalid) 不该被接受")
    }
}

@Test func searchQueryStripsLineAndColumnSuffixes() {
    func parse(_ query: String, root: String? = "/work/proj") -> String {
        let result = FileReference.parseQuery(query, projectRoot: root)
        guard let location = result.location else { return result.path }
        return "\(result.path)@\(location.line)" + (location.column.map { ":\($0)" } ?? "")
    }
    #expect(parse("Sources/Foo.swift:123") == "Sources/Foo.swift@123")
    #expect(parse("Sources/Foo.swift:123:5") == "Sources/Foo.swift@123:5")
    #expect(parse("Sources/Foo.swift:12-20") == "Sources/Foo.swift@12")
    #expect(parse("./Sources/Foo.swift:12") == "Sources/Foo.swift@12")
    #expect(parse("Foo.swift#L12") == "Foo.swift@12")
    #expect(parse("Foo.swift#L12-L20") == "Foo.swift@12")
    #expect(parse("Foo.swift#L12C7") == "Foo.swift@12:7")
    #expect(parse("/work/proj/Sources/Foo.swift:9") == "Sources/Foo.swift@9", "项目内的绝对路径换成相对路径")
    #expect(parse("/elsewhere/Foo.swift:9") == "/elsewhere/Foo.swift@9", "项目外的绝对路径原样留着")
    #expect(parse("/work/proj/Sources/Foo.swift:9", root: nil) == "/work/proj/Sources/Foo.swift@9")
    #expect(parse("file:///work/proj/a%20b.swift:3") == "a b.swift@3")
    // 编译器输出结尾多一个冒号；Markdown 里带着反引号
    #expect(parse("Sources/Foo.swift:12:5:") == "Sources/Foo.swift@12:5")
    #expect(parse("`Sources/Foo.swift:12`") == "Sources/Foo.swift@12")
    #expect(parse("  Sources/Foo.swift:12  ") == "Sources/Foo.swift@12")
    #expect(parse("Foo.swift:0") == "Foo.swift@1")
}

@Test func searchQueryWithoutLineBehavesAsBefore() {
    for query in ["Foo.swift", "amdl", "Sources/Foo", "model/app"] {
        let result = FileReference.parseQuery(query, projectRoot: "/work/proj")
        #expect(result.path == query && result.location == nil, "\(query)")
    }
    // 文件名里的冒号：只看末尾的数字，不是数字的不拆
    #expect(FileReference.parseQuery("a:b.swift", projectRoot: nil) == ("a:b.swift", nil))
    #expect(FileReference.parseQuery("notes:draft", projectRoot: nil).location == nil)
    #expect(FileReference.parseQuery("a:b.swift:7", projectRoot: nil) == ("a:b.swift", SourceLocation(line: 7)))
    #expect(FileReference.parseQuery("v1.2:3abc", projectRoot: nil).location == nil, "冒号后面不全是数字")
    // 只有位置没有路径：不拆，原样当名字搜
    #expect(FileReference.parseQuery(":12", projectRoot: nil) == (":12", nil))
    #expect(FileReference.parseQuery("#L12", projectRoot: nil) == ("#L12", nil))
    #expect(FileReference.parseQuery("12", projectRoot: nil) == ("12", nil))
}

@Test func exactPathMatchRanksFirst() {
    let index = ["Tests/Sources/Foo.swift", "Sources/Foo.swift", "Sources/FooBar/Foo.swift"].map(FileSearchEntry.init)
    #expect(FileSearch.search("Sources/Foo.swift", in: index).first?.entry.path == "Sources/Foo.swift")
}
