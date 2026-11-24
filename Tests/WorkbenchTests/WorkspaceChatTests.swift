import AppKit
import Core
import DesignSystem
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import Workbench

private struct MemoryChatSettings: AIChatSettingsStoring {
    let settings = Locked<AIChatSettings?>(nil)
    func load() throws -> AIChatSettings? { settings.value }
    func save(_ value: AIChatSettings) throws { settings.value = value }
}

@Test func aiChatMarkdownOnlyMakesWebLinksClickable() {
    let markdown = "[文档](https://example.com) [本地文件](file:///tmp/example.txt) [应用命令](custom://open)"
    let text = ChatMarkdownText.attributed(markdown)
    #expect(String(text.characters) == "文档 本地文件 应用命令")
    #expect(text.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
}

@Test @MainActor func aiSettingsFlushesEditsWhenTheNativeWindowCloses() throws {
    let store = MemoryChatSettings()
    let client = OpenAIWorkspaceChat(transport: ScriptedAIChatTransport([]))
    let settings = WorkspaceChatSettings(store: store, client: client, seed: { nil })
    let model = WorkspaceChatSettingsModel(controller: settings, client: client)
    model.open()
    #expect(model.draft.keys == [""])
    model.draft.keys[0] = "sk-test-key"
    model.draft.effort = "low"
    model.close()
    #expect(try store.load() == AIChatSettings(effort: "low", keys: ["sk-test-key"]))
    #expect(settings.settings?.effort == "low")
}

@Test @MainActor func aiChatDrawerKeepsTheExistingEditorMountedAtTheSameSize() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("editor.txt")
        try Data("editor stays visible".utf8).write(to: file)
        let defaults = try #require(UserDefaults(suiteName: "agentidea-chat-tests-\(UUID())"))
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"),
                                       chatSettings: WorkspaceChatSettings(store: MemoryChatSettings(), seed: { nil }))
        workbench.openProject(file)
        let view = WorkbenchView().frame(width: 1_100, height: 640)
            .environmentObject(workbench).environmentObject(workbench.preferences).environmentObject(Updater())
        let hosting = NSHostingView(rootView: view)
        let bounds = CGRect(x: -20_000, y: -20_000, width: 1_100, height: 640)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let editor = workbench.renderer.webView
        await waitForChat {
            hosting.layoutSubtreeIfNeeded()
            return editor.window === window && editor.frame.width > 600
        }
        let editorFrame = editor.frame
        func composer(in view: NSView) -> WorkspaceChatPlaceholder? {
            if let view = view as? WorkspaceChatPlaceholder { return view }
            return view.subviews.lazy.compactMap { composer(in: $0) }.first
        }

        workbench.toggleAIChat()
        await waitForChat {
            hosting.layoutSubtreeIfNeeded()
            return composer(in: hosting)?.window === window
        }
        #expect(editor.window === window && editor.frame == editorFrame)
        #expect(workbench.active?.activeTab?.title == "editor.txt")
        #expect(composer(in: hosting)?.string.isEmpty == true)
        workbench.toggleAIChat()
        await waitForChat { composer(in: hosting) == nil }
        #expect(editor.window === window && editor.frame == editorFrame)
    }
}

@Test @MainActor func aiChatTabsKeepTheirOwnProjectAndConversationWhenSwitchingProjects() async throws {
    try await withTemporaryDirectory { directory in
        let alpha = directory.appendingPathComponent("alpha")
        let beta = directory.appendingPathComponent("beta")
        for project in [alpha, beta] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try Data("initial".utf8).write(to: project.appendingPathComponent("note.txt"))
        }
        let fixture = ScriptedAIChatTransport.self
        let transport = fixture.init([
            .init(events: [fixture.completed([fixture.call(.replaceText, ["path": "note.txt", "old_text": "initial", "new_text": "alpha edited"])])]),
            .init(events: [fixture.completed([fixture.message("alpha 完成")])]),
            .init(events: [fixture.completed([fixture.call(.createFile, ["path": "beta-only.txt", "text": "beta created"])])]),
            .init(events: [fixture.completed([fixture.message("beta 完成")])]),
        ])
        let settings = WorkspaceChatSettings(store: MemoryChatSettings()) { .init(keys: ["sk-test-chat"]) }
        let defaults = try #require(UserDefaults(suiteName: "agentidea-chat-tests-\(UUID())"))
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"),
                                       chatSettings: settings, chatClient: OpenAIWorkspaceChat(transport: transport))
        workbench.openProject(alpha)
        let alphaSession = try #require(workbench.active)
        alphaSession.openFile(alpha.appendingPathComponent("note.txt"), pinned: true)
        let editorTab = try #require(alphaSession.activeTab)
        workbench.newAIChat()
        let firstTab = try #require(workbench.activeChat)
        let first = firstTab.chat
        #expect(alphaSession.activeTab == editorTab)
        first.draft = "alpha prompt"
        first.send()
        workbench.newAIChat()
        let secondTab = try #require(workbench.activeChat)
        let second = secondTab.chat
        #expect(first !== second)
        #expect(workbench.chatTabs.map(\.title) == ["alpha 1", "alpha 2"])
        #expect(alphaSession.tabs.map(\.title) == ["note.txt"])
        second.draft = "unsent in the second tab"

        workbench.openProject(beta)
        let betaSession = try #require(workbench.active)
        #expect(workbench.activeChat?.id == secondTab.id)
        workbench.newAIChat()
        let betaChat = try #require(workbench.activeChat?.chat)
        #expect(betaChat.workspace.root == betaSession.project.root)
        #expect(first.workspace.root == alphaSession.project.root)
        await waitForChat { !first.running }
        #expect(first.turns.last?.answer == "alpha 完成")
        #expect(try String(contentsOf: alpha.appendingPathComponent("note.txt"), encoding: .utf8) == "alpha edited")
        #expect(try String(contentsOf: beta.appendingPathComponent("note.txt"), encoding: .utf8) == "initial")
        #expect(alphaSession.undoTitle == "撤销AI 编辑 note.txt")

        betaChat.draft = "beta prompt"
        betaChat.send()
        await waitForChat { !betaChat.running }
        #expect(betaChat.turns.count == 1)
        #expect(betaChat.turns.last?.answer == "beta 完成")
        #expect(FileManager.default.fileExists(atPath: beta.appendingPathComponent("beta-only.txt").path))
        #expect(!FileManager.default.fileExists(atPath: alpha.appendingPathComponent("beta-only.txt").path))
        let requests = await transport.requests
        let betaBody = try #require(requests.dropFirst(2).first?.httpBody)
        #expect(!String(decoding: betaBody, as: UTF8.self).contains("alpha prompt"))

        workbench.activate(alphaSession.id)
        workbench.selectAIChat(secondTab.id)
        #expect(workbench.activeChat?.chat === second && second.draft == "unsent in the second tab")
        workbench.toggleAIChat()
        #expect(!workbench.isChatPresented && workbench.activeChat?.id == secondTab.id)
        workbench.toggleAIChat()
        #expect(workbench.isChatPresented && workbench.activeChat?.id == secondTab.id)
        workbench.selectAIChat(firstTab.id)
        #expect(workbench.activeChat?.chat === first)
        workbench.closeAIChat(firstTab.id)
        #expect(workbench.activeChat?.chat === second)
        workbench.closeProject(betaSession.id)
        #expect(workbench.chatTabs.map(\.title) == ["alpha 2"])
    }
}

@Test @MainActor func aiChatWorkspaceSelectorOnlySwitchesToOpenProjectsAndKeepsTheDraftReferences() async throws {
    try await withTemporaryDirectory { directory in
        let folders = ["alpha", "beta", "closed"].map { directory.appendingPathComponent($0, isDirectory: true) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let file = directory.appendingPathComponent("external.txt")
        try Data("external reference contents".utf8).write(to: file)
        let fixture = ScriptedAIChatTransport.self
        let transport = fixture.init([
            .init(events: [fixture.completed([fixture.call(.readFile, ["path": "reference://1", "start_line": 1, "line_count": 1])])]),
            .init(events: [fixture.completed([fixture.message("done")])]),
        ])
        let settings = WorkspaceChatSettings(store: MemoryChatSettings(), seed: { .init(keys: ["sk-workspace-test"]) })
        let defaults = try #require(UserDefaults(suiteName: "agentidea-chat-tests-\(UUID())"))
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"),
                                       chatSettings: settings, chatClient: .init(transport: transport))
        for folder in folders.prefix(2) { workbench.openProject(folder) }
        let beta = try #require(workbench.active)
        let alpha = try #require(workbench.sessions.first)
        workbench.newAIChat()
        let tab = try #require(workbench.activeChat)
        tab.chat.draft = "read the reference"
        tab.chat.addReferences([file, file])
        workbench.selectAIChatWorkspace(folders[2].path)
        #expect(workbench.activeChat?.chat === tab.chat)

        workbench.selectAIChatWorkspace(alpha.id)
        let selected = try #require(workbench.activeChat)
        #expect(selected.id == tab.id && selected.projectID == alpha.id && workbench.active === beta)
        #expect(selected.chat.draft == "read the reference")
        #expect(selected.chat.pendingReferences.map(\.name) == ["external.txt"])
        selected.chat.send()
        await waitForChat { !selected.chat.running }
        #expect(selected.chat.turns.last?.answer == "done")
        #expect(selected.chat.pendingReferences.isEmpty)
        let bodies = await transport.requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
        #expect(bodies.first?.contains("external.txt") == true)
        #expect(bodies.last?.contains("external reference contents") == true)

        workbench.selectAIChatWorkspace(beta.id)
        #expect(workbench.activeChat?.projectID == beta.id)
        #expect(workbench.chatTabs.count == 2 && selected.chat.turns.count == 1)
        #expect(workbench.activeChat?.chat.turns.isEmpty == true)
    }
}

@Test @MainActor func aiChatDropDecodesTheTreeSelectionAndFinderFileURLs() throws {
    let urls = [URL(fileURLWithPath: "/tmp/a file.md"), URL(fileURLWithPath: "/tmp/another folder")]
    let pasteboard = NSPasteboard.withUniqueName()
    let item = NSPasteboardItem()
    item.setPropertyList(urls.map(\.path), forType: TreeRowInteraction.pasteboardType)
    pasteboard.writeObjects([item])
    #expect(WorkspaceChatReferenceDrop.urls(on: pasteboard) == urls)
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
    #expect(WorkspaceChatReferenceDrop.urls(on: pasteboard) == urls)
}

@Test @MainActor func aiWorkspaceEditKeepsUnsavedEditorDraftAndSupportsUndo() async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appendingPathComponent("note.txt")
        try Data("on disk".utf8).write(to: file)
        let settings = WorkspaceChatSettings(store: MemoryChatSettings(), seed: { nil })
        let defaults = try #require(UserDefaults(suiteName: "agentidea-chat-tests-\(UUID())"))
        let model = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"), chatSettings: settings)
        model.openProject(directory)
        let project = try #require(model.active)
        project.setActive(false)
        project.openFile(file, pinned: true)
        project.applyEdit(path: file.path, text: "unsaved editor draft")
        let workspace = try AIWorkspace(root: directory)
        await #expect(throws: (any Error).self) {
            try await project.invokeChatTool(.replace(path: "note.txt", old: "on disk", new: "replaced"), workspace: workspace)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "on disk")
        #expect(project.drafts.values.contains("unsaved editor draft"))
        project.saveAll()
        let result = try await project.invokeChatTool(.replace(path: "note.txt", old: "unsaved editor draft", new: "replaced"), workspace: workspace)
        #expect(result.edited)
        #expect(try String(contentsOf: file, encoding: .utf8) == "replaced")
        project.undo()
        await waitForChat { project.canRedo }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unsaved editor draft")
    }
}

@Test @MainActor func aiSettingsKeepAnExplicitlyEmptyKeyGroupWithoutReimporting() throws {
    let store = MemoryChatSettings()
    let fixture = AIChatSettings(model: "gpt-6.1-sol", keys: ["sk-test-first", "sk-test-second"])
    let chat = WorkspaceChatSettings(store: store, seed: { fixture })
    #expect(try chat.load() == fixture)
    #expect(try store.load() == fixture)
    try chat.save(.init(model: fixture.model, keys: []))
    let afterRestart = WorkspaceChatSettings(store: store) {
        Issue.record("已有设置时不能重新导入 KBR")
        return fixture
    }
    #expect(try afterRestart.load().keys.isEmpty)
}

@Test @MainActor func aiChatClosingSessionCancelsTheStreamAndPreventsALateEdit() async throws {
    try await withTemporaryDirectory { directory in
        let transport = WaitingChatTransport()
        let settings = WorkspaceChatSettings(store: MemoryChatSettings()) { .init(keys: ["sk-fixture"]) }
        let defaults = try #require(UserDefaults(suiteName: "agentidea-chat-tests-\(UUID())"))
        let workbench = WorkbenchModel(git: nil, defaults: defaults, recentFile: directory.appendingPathComponent("recent.json"),
                                       chatSettings: settings, chatClient: .init(transport: transport))
        workbench.openProject(directory)
        workbench.newAIChat()
        let tab = try #require(workbench.activeChat)
        let chat = tab.chat
        chat.draft = "create a file"
        chat.send()
        await transport.waitUntilStarted()
        workbench.toggleAIChat()
        #expect(!workbench.isChatPresented && chat.running)
        workbench.closeAIChat(tab.id)
        await waitForChat { !chat.running }
        await transport.finishWithLateEdit()
        #expect(chat.turns.last?.problem == "已停止")
        #expect(workbench.chatTabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late.txt").path))
    }
}

private actor WaitingChatTransport: AIChatTransport {
    private var stream: AsyncThrowingStream<String, Error>.Continuation?
    private var observer: CheckedContinuation<Void, Never>?

    func stream(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        stream = pair.continuation
        observer?.resume()
        observer = nil
        return (200, pair.stream)
    }

    func waitUntilStarted() async {
        if stream != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func finishWithLateEdit() {
        let call = ScriptedAIChatTransport.call(.createFile, ["path": "late.txt", "text": "late"])
        stream?.yield("data: " + ScriptedAIChatTransport.completed([call]))
        stream?.finish()
    }
}

@MainActor private func waitForChat(_ ready: () -> Bool) async {
    let deadline = Date().addingTimeInterval(10)
    while !ready(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        await Task.yield()
    }
    #expect(ready())
}
