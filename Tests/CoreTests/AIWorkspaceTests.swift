import Core
import Foundation
import SQLite3
import Testing
import TestSupport

@Test func aiChatUsesKBReaderDrawerBoundsAndMarkdownBlocks() throws {
    #expect(ChatPanelLayout.clamp(380, windowWidth: 900) == 300)
    #expect(ChatPanelLayout.clamp(999, windowWidth: 1_500) == 500)
    #expect(ChatPanelLayout.range(windowWidth: 720) == 240...240)
    let text = """
    ## 结果

    ```swift
    let value = 1
    ```

    | 名称 | 值 |
    | --- | --- |
    | value | 1 |

    > 已更新
    """
    let blocks = ChatMarkdownBlock.split(text)
    #expect(blocks.contains(.code(language: "swift", body: "let value = 1")))
    #expect(blocks.contains(.table(header: ["名称", "值"], rows: [["value", "1"]])))
    #expect(blocks.contains(.quote("已更新")))
    #expect(ChatMarkdownBlock.inlineFriendly("## 结果\n- 编辑") == "**结果**\n• 编辑")
}

@Test func aiWorkspaceRestrictsFilesToItsOwnRootAndPreservesOriginalBytes() throws {
    try withTemporaryDirectory { temp in
        let manager = FileManager.default
        let project = temp.appendingPathComponent("project")
        let neighbor = temp.appendingPathComponent("neighbor")
        try manager.createDirectory(at: project, withIntermediateDirectories: false)
        try manager.createDirectory(at: neighbor, withIntermediateDirectories: false)
        let homeWithDifferentCase = temp.appendingPathComponent("PROJECT/home", isDirectory: true)
        #expect(throws: AIWorkspace.Problem.unsuitableRoot) {
            try AIWorkspace(root: project, home: homeWithDifferentCase)
        }
        let outside = neighbor.appendingPathComponent("outside.txt")
        try Data("secret outside".utf8).write(to: outside)
        try manager.createSymbolicLink(at: project.appendingPathComponent("outside.txt"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: project.appendingPathComponent("outside"), withDestinationURL: neighbor)
        try manager.linkItem(at: outside, to: project.appendingPathComponent("hardlink.txt"))
        try manager.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: false)
        try Data("secret config".utf8).write(to: project.appendingPathComponent(".env.local"))
        let file = project.appendingPathComponent("样例.txt")
        let original = Data("\u{FEFF}line one\r\nline two\r\n".utf8)
        try original.write(to: file)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let workspace = try AIWorkspace(root: project)
        #expect(try workspace.list() == ["样例.txt"])
        #expect(try workspace.read("样例.txt", startLine: 2, lineCount: 1).contains("2\tline two"))
        #expect(try workspace.search("line two", under: "").contains("样例.txt:2:"))
        #expect(try workspace.search("secret", under: "") == "没有找到匹配内容")
        for path in ["../neighbor/outside.txt", outside.path, ".env.local", ".git/config", "outside/outside.txt", "outside.txt", "hardlink.txt"] {
            #expect(throws: AIWorkspace.Problem.self) { try workspace.read(path, startLine: 1, lineCount: 1) }
            #expect(throws: AIWorkspace.Problem.self) { try workspace.replace(path, old: "secret", new: "changed") }
        }
        #expect(throws: AIWorkspace.Problem.unsafePath) { try workspace.create("outside/new.txt", text: "x") }
        #expect(try Data(contentsOf: outside) == Data("secret outside".utf8))
        #expect(!manager.fileExists(atPath: neighbor.appendingPathComponent("new.txt").path))

        let edit = try workspace.replace("样例.txt", old: "line two", new: "第二行")
        #expect(edit.before == original)
        #expect(try Data(contentsOf: file) == Data("\u{FEFF}line one\r\n第二行\r\n".utf8))
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o755)
        #expect(throws: AIWorkspace.Problem.exists) { try workspace.create("样例.txt", text: "overwrite") }
        #expect(try workspace.create("new.txt", text: "new").before == nil)
        #expect(try workspace.list() == ["new.txt", "样例.txt"])
    }
}

@Test func aiWorkspaceRejectsAmbiguousReplacementsAndAReplacedRoot() throws {
    try withTemporaryDirectory { temp in
        let manager = FileManager.default
        let project = temp.appendingPathComponent("project")
        try manager.createDirectory(at: project, withIntermediateDirectories: false)
        let workspace = try AIWorkspace(root: project)
        _ = try workspace.create("same.txt", text: "aaaa")
        #expect(throws: AIWorkspace.Problem.ambiguousText) { try workspace.replace("same.txt", old: "aaa", new: "x") }
        #expect(throws: AIWorkspace.Problem.missingText) { try workspace.replace("same.txt", old: "missing", new: "x") }
        #expect(throws: AIWorkspace.Problem.tooLarge) { try workspace.create("large.txt", text: String(repeating: "x", count: AIWorkspace.maxFileBytes + 1)) }
        try manager.moveItem(at: project, to: temp.appendingPathComponent("old"))
        try manager.createDirectory(at: project, withIntermediateDirectories: false)
        #expect(throws: AIWorkspace.Problem.changed) { try workspace.list() }
        #expect(throws: AIWorkspace.Problem.unsuitableRoot) { try AIWorkspace(root: temp, home: project) }
    }
}

@Test func aiChatDefaultsImportKBRKeyOneAndThreeInOrder() throws {
    try withTemporaryDirectory { temp in
        let path = temp.appendingPathComponent("settings.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO settings VALUES ('openai.api_key', 'sk-fixture-a, sk-fixture-a; sk-fixture-b，sk-fixture-c'),
            ('chat.model', 'gpt-chat-fixture'), ('openai.model', 'gpt-search-fixture'),
            ('chat.effort', 'low'), ('qoder.token', 'sk-not-openai');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let settings = try #require(KBReaderChatDefaults.read(from: path))
        #expect(settings == AIChatSettings(model: "gpt-chat-fixture", effort: "low", keys: ["sk-fixture-a", "sk-fixture-c"]))
        #expect(settings.validationError == nil)
        #expect(AIChatSettings(model: "qoder", keys: ["sk-fixture"]).validationError != nil)
        #expect(AIChatSettings(keys: ["sk- bad"]).validationError != nil)
    }
}

@Test func aiSettingsFileIsPrivateAndReadsWithoutFollowingLinks() throws {
    try withTemporaryDirectory { temp in
        let directory = temp.appendingPathComponent("config")
        let settings = AIChatSettings(model: "gpt-fixture", keys: ["sk-fixture-first", "sk-fixture-third"])
        let store = AIChatSettingsFile(directory: directory)
        #expect(try store.load() == nil)
        try store.save(settings)
        #expect(try AIChatSettingsFile(directory: directory).load() == settings)
        let file = directory.appendingPathComponent("ai-chat.json")
        let manager = FileManager.default
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try store.load() }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let moved = temp.appendingPathComponent("other.json")
        try manager.moveItem(at: file, to: moved)
        try manager.createSymbolicLink(at: file, withDestinationURL: moved)
        #expect(throws: (any Error).self) { try store.load() }
        let empty = AIChatSettings(model: settings.model, keys: [])
        try store.save(empty)
        #expect(try store.load() == empty)
        #expect(try JSONDecoder().decode(AIChatSettings.self, from: Data(contentsOf: moved)) == settings)
    }
}

@Test func aiChatFallsBackBetweenKeysWithoutReapplyingToolsOrReplayingForeignReasoning() async throws {
    let fixture = ScriptedAIChatTransport.self
    let transport = fixture.init([
        .init(events: [fixture.completed([
            ["type": "reasoning", "encrypted_content": "key-scoped-reasoning", "summary": []],
            fixture.call(.replaceText, ["path": "README.md", "old_text": "old", "new_text": "new"])
        ])]),
        .init(status: 429),
        .init(events: [fixture.event(["type": "response.reasoning_summary_text.delta", "delta": "检查"]),
                       fixture.event(["type": "response.output_text.delta", "delta": "已修改"]),
                       fixture.completed([fixture.message("已修改")])])
    ])
    let calls = Locked<[AIWorkspaceTool.Request]>([])
    let events = Locked<[OpenAIWorkspaceChat.Event]>([])
    let answer = try await OpenAIWorkspaceChat(transport: transport).respond(
        settings: .init(keys: ["sk-test-primary", "sk-test-backup"]),
        history: [.init(role: .user, text: "上一问"), .init(role: .assistant, text: "上一答")], prompt: "改文件",
        onEvent: { events.value.append($0) }, invoke: { request in
            calls.value.append(request)
            return .init(summary: "已编辑文件", edited: true)
        })
    #expect(answer == "已修改")
    #expect(calls.value == [.replace(path: "README.md", old: "old", new: "new")])
    #expect(events.value.contains(.text("已修改")) && events.value.contains(.reason("检查")))
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer sk-test-primary", "Bearer sk-test-primary", "Bearer sk-test-backup"])
    let bodies = try requests.map {
        let body = try #require($0.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    #expect(bodies[0]["store"] as? Bool == false)
    #expect(bodies[0]["parallel_tool_calls"] as? Bool == false)
    let second = try #require(bodies[1]["input"] as? [[String: Any]])
    let third = try #require(bodies[2]["input"] as? [[String: Any]])
    #expect(second.contains { $0["encrypted_content"] as? String == "key-scoped-reasoning" })
    #expect(!third.contains { $0["type"] as? String == "reasoning" })
    #expect(third.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "test-call" })
    #expect(third.contains { $0["content"] as? String == "上一问" })
}

@Test func aiSettingsConnectionCheckUsesOnlyTheSelectedKeyAndNoWorkspaceTools() async throws {
    let fixture = ScriptedAIChatTransport.self
    let transport = fixture.init([.init(status: 401), .init(events: [fixture.completed([fixture.message("ok")])])])
    let client = OpenAIWorkspaceChat(transport: transport)
    let settings = AIChatSettings(model: "gpt-fixture", effort: "low", keys: ["sk-test-a", "sk-test-b"])
    await #expect(throws: OpenAIWorkspaceChat.Failure.http(401)) {
        try await client.checkConnection(settings: settings, key: "sk-test-a")
    }
    #expect(try await client.checkConnection(settings: settings, key: "sk-test-b") == "ok")
    let requests = await transport.requests
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer sk-test-a", "Bearer sk-test-b"])
    let data = try #require(requests.last?.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["model"] as? String == "gpt-fixture")
    #expect((body["reasoning"] as? [String: String])?["effort"] == "low")
    #expect(body["tools"] == nil && body["store"] as? Bool == false)
    #expect((body["input"] as? [[String: String]])?.first?["content"] == "ping")
}

@Test func aiSettingsDiscoversKBReaderTextModelsFromTheFirstWorkingKey() async {
    let listing = #"{"data":[{"id":"gpt-6.2-sol"},{"id":"gpt-6.2-sol"},{"id":"gpt-6.1-sol"},{"id":"gpt-6.1-sol-2026-11-01"},{"id":"gpt-audio"},{"id":"o3"}]}"#
    let transport = ScriptedAIChatTransport([.init(status: 401), .init(events: [listing], sse: false)])
    let models = await OpenAIWorkspaceChat(transport: transport).discoverModels(keys: ["sk-test-a", "sk-test-b", "sk-test-c"])
    #expect(models == ["gpt-6.2-sol", "gpt-6.1-sol", "o3"])
    #expect(AIChatSettings(model: "o3").validationError == nil)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.url?.path == "/v1/models" && $0.httpMethod == "GET" })
}

@Test func aiSettingsMigratesTheOldDefaultAndRetainsExplicitModelSelections() throws {
    try withTemporaryDirectory { directory in
        let store = AIChatSettingsFile(directory: directory)
        let file = directory.appendingPathComponent("ai-chat.json")
        let keys = ["sk-old-default-test"]
        let legacy = AIChatSettings(model: "gpt-6.1-sol", effort: "high", keys: keys)
        try JSONEncoder().encode(legacy).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try store.load() == AIChatSettings(model: "gpt-6.2-sol", effort: "high", keys: keys))
        try store.save(legacy)
        #expect(try store.load() == legacy)
    }
}

@Test func aiChatReferencesReadOnlyTheChosenFileOrDirectory() throws {
    try withTemporaryDirectory { directory in
        let folder = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("selected.txt")
        let child = folder.appendingPathComponent("child.txt")
        for target in [file, child] { try Data(target.lastPathComponent.utf8).write(to: target) }
        let selected = try AIChatReference(id: 1, url: file)
        let scoped = try AIChatReference(id: 2, url: folder)
        let references = [selected, scoped]
        #expect(try AIChatReference.invoke(.read(path: selected.toolPath, startLine: 1, lineCount: 1), references: references)
            .output.contains("1\tselected.txt"))
        #expect(try AIChatReference.invoke(.list(path: scoped.toolPath), references: references).output == "child.txt")
        #expect(try AIChatReference.invoke(.read(path: scoped.toolPath + "/child.txt", startLine: 1, lineCount: 1), references: references)
            .output.contains("1\tchild.txt"))
        #expect(throws: AIWorkspace.Problem.unsafePath) {
            try AIChatReference.invoke(.read(path: scoped.toolPath + "/../selected.txt", startLine: 1, lineCount: 1), references: references)
        }
        #expect(throws: AIWorkspace.Problem.unsafePath) {
            try AIChatReference.invoke(.read(path: selected.toolPath + "/nested/child.txt", startLine: 1, lineCount: 1), references: references)
        }
        #expect(throws: (any Error).self) {
            try AIChatReference.invoke(.create(path: scoped.toolPath + "/unexpected.txt", text: "blocked"), references: references)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("unexpected.txt").path))
    }
}

@Test func aiChatDoesNotExecuteAToolFromAnIncompleteResponse() async throws {
    let fixture = ScriptedAIChatTransport.self
    let item = fixture.call(.createFile, ["path": "unexpected.txt", "text": "bad"])
    let transport = fixture.init([.init(events: [fixture.event(["type": "response.output_item.done", "item": item]),
                                                fixture.event(["type": "response.incomplete"])])])
    await #expect(throws: OpenAIWorkspaceChat.Failure.incomplete) {
        try await OpenAIWorkspaceChat(transport: transport).respond(settings: .init(keys: ["sk-test"]), history: [], prompt: "test",
            onEvent: { _ in }, invoke: { _ in Issue.record("不得执行未完成的工具调用"); return .init(summary: "") })
    }
    #expect(await transport.requests.count == 1)
}
