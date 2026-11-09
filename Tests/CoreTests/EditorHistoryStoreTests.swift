import Core
import Foundation
import Testing
import TestSupport

/// 指纹：稳定（不随进程变，十六进制 SHA-256）、行尾归一，其余按字节。
@Test func textFingerprintIsStableAndIgnoresLineEndingsOnly() {
    #expect(TextFingerprint.of("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "空串的 SHA-256：跨进程不变")
    #expect(TextFingerprint.of("one\r\ntwo\r\n") == TextFingerprint.of("one\ntwo\n"), "CRLF 与编辑器里的 LF 是同一份")
    #expect(TextFingerprint.of("one\ntwo\n") != TextFingerprint.of("one\ntwo"))
    #expect(TextFingerprint.of("caf\u{e9}") != TextFingerprint.of("cafe\u{301}"), "Unicode 等价但字节不同的不算同一份：宁可不装")
}

/// 存取：指纹对得上才给，对不上删掉这条；存得下来、跨实例（重启）读得回来；只看过没改的历史不算编辑。
@Test func editorHistoryStoreSavesLoadsAndDropsMismatches() throws {
    try withTemporaryDirectory { directory in
        let root = directory.appendingPathComponent("undo")
        let file = directory.appendingPathComponent("a.txt").path
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let store = EditorHistoryStore(directory: root)
        #expect(store.load(path: file, textHash: "h1") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path), "从没存过就不建目录")

        store.save(path: file, textHash: "h1", history: #"{"done":[{"changes":[]}],"undone":[]}"#)
        // 重启：新实例从盘上读
        let reopened = EditorHistoryStore(directory: root)
        #expect(reopened.load(path: file, textHash: "h1") == #"{"done":[{"changes":[]}],"undone":[]}"#)
        // 文件在别处被改过：指纹不对，这条作废
        #expect(reopened.load(path: file, textHash: "h2") == nil)
        #expect(reopened.entries[file] == nil)
        #expect(EditorHistoryStore(directory: root).load(path: file, textHash: "h1") == nil, "删掉的是盘上的记录")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers == [EditorHistoryStore.indexFileName], "数据文件跟着删")

        #expect(EditorHistoryStore.recordsEdits(#"{"done":[{"changes":[{"from":{"line":0}}]}],"undone":[]}"#))
        #expect(!EditorHistoryStore.recordsEdits(#"{"done":[{"ranges":[]}],"undone":[]}"#))
    }
}

/// 太大的不存（并删掉旧的）；同一份内容反复存不重写。
@Test func editorHistoryStoreSkipsOversizedRecords() throws {
    try withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("a.txt").path
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let store = EditorHistoryStore(directory: directory.appendingPathComponent("undo"), limits: .init(maxRecordBytes: 10))
        store.save(path: file, textHash: "h", history: "short")
        #expect(store.entries[file]?.bytes == 5)
        store.save(path: file, textHash: "h", history: String(repeating: "x", count: 11))
        #expect(store.entries[file] == nil)
    }
}

/// 按最近使用淘汰（条数、总量），过期的删掉；取一次就算用过。
@Test func editorHistoryStoreEvictsLeastRecentlyUsedAndExpired() throws {
    try withTemporaryDirectory { directory in
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let paths = (0..<4).map { directory.appendingPathComponent("f\($0).txt").path }
        for path in paths { try "x".write(toFile: path, atomically: true, encoding: .utf8) }
        let store = EditorHistoryStore(directory: directory.appendingPathComponent("undo"),
                                       limits: .init(maxRecordBytes: 100, maxTotalBytes: 25, maxRecords: 3, maxAge: 1000),
                                       now: { clock })
        for path in paths.prefix(3) {
            store.save(path: path, textHash: "h", history: "0123456789")
            clock += 1
        }
        // 三条 30 字节超过总量 25：最旧的 f0 让位
        #expect(Set(store.entries.keys) == Set([paths[1], paths[2]]))
        // 用一下 f1，它就比 f2 新
        #expect(store.load(path: paths[1], textHash: "h") != nil)
        clock += 1
        store.save(path: paths[3], textHash: "h", history: "0123456789")
        #expect(Set(store.entries.keys) == Set([paths[1], paths[3]]), "淘汰最久没用的 f2")

        // 条数上限
        let byCount = EditorHistoryStore.evictions(
            ["a": .init(file: "a", textHash: "", bytes: 1, lastUsed: clock), "b": .init(file: "b", textHash: "", bytes: 1, lastUsed: clock + 1),
             "c": .init(file: "c", textHash: "", bytes: 1, lastUsed: clock + 2)],
            limits: .init(maxRecords: 2), now: clock + 2)
        #expect(byCount == ["a"])

        // 过期：超过 maxAge 没用过的，取的时候不给、清理时删掉
        clock += 2000
        #expect(store.load(path: paths[3], textHash: "h") == nil)
        store.prune()
        #expect(store.entries.isEmpty)
    }
}

/// 改名 / 移动：文件与目录下的一并换路径；删除：目录下的一并删；第一次读索引时清掉磁盘上已经不在的路径与孤儿文件。
@Test func editorHistoryStoreFollowsMovesAndPrunesMissingPaths() throws {
    try withTemporaryDirectory { directory in
        let root = directory.appendingPathComponent("undo")
        let store = EditorHistoryStore(directory: root, pathExists: { _ in true })
        store.save(path: "/p/dir/a.txt", textHash: "a", history: "A")
        store.save(path: "/p/dir/sub/b.txt", textHash: "b", history: "B")
        store.save(path: "/p/dir2/c.txt", textHash: "c", history: "C")
        store.save(path: "/p/new/a.txt", textHash: "old", history: "OLD")

        store.move(from: "/p/dir", to: "/p/new")
        #expect(Set(store.entries.keys) == Set(["/p/new/a.txt", "/p/new/sub/b.txt", "/p/dir2/c.txt"]), "dir2 不是 dir 的子目录")
        #expect(store.load(path: "/p/new/a.txt", textHash: "a") == "A", "目标上原来的那条被顶掉")
        #expect(store.load(path: "/p/new/sub/b.txt", textHash: "b") == "B")

        // 只改大小写
        store.move(from: "/p/new/a.txt", to: "/p/new/A.txt")
        #expect(store.load(path: "/p/new/A.txt", textHash: "a") == "A")

        store.remove(path: "/p/new")
        #expect(Set(store.entries.keys) == Set(["/p/dir2/c.txt"]))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).count == 2, "索引 + c 的数据文件")

        // 孤儿数据文件、路径已不在磁盘上的条目：下次启动（第一次读索引）清掉
        try Data("x".utf8).write(to: root.appendingPathComponent("orphan.json"))
        let restarted = EditorHistoryStore(directory: root, pathExists: { $0 != "/p/dir2/c.txt" })
        #expect(restarted.entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [EditorHistoryStore.indexFileName])
    }
}
