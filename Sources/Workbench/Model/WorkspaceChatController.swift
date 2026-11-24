import Core
import Foundation

@MainActor
final class WorkspaceChatSettings: ObservableObject {
    private let store: any AIChatSettingsStoring
    private let seed: () -> AIChatSettings?
    private let client: OpenAIWorkspaceChat
    private var modelDiscovery: Task<Void, Never>?
    private var discoveryKeys: [String]?
    @Published private(set) var settings: AIChatSettings?
    @Published private(set) var discoveredModels: [String] = []

    init(store: any AIChatSettingsStoring = AIChatSettingsFile(), client: OpenAIWorkspaceChat = .init(),
         seed: @escaping () -> AIChatSettings? = { KBReaderChatDefaults.read().map { AIChatSettings(keys: $0.keys) } }) {
        self.store = store
        self.client = client
        self.seed = seed
    }

    func load() throws -> AIChatSettings {
        if let settings { return settings }
        if let stored = try store.load() {
            settings = stored
            return stored
        }
        if let imported = seed() {
            try save(imported)
            return imported
        }
        let defaults = AIChatSettings()
        settings = defaults
        return defaults
    }

    func save(_ settings: AIChatSettings) throws {
        let normalized = settings.normalized
        if let reason = normalized.validationError { throw OpenAIWorkspaceChat.Failure.invalidSettings(reason) }
        try store.save(normalized)
        self.settings = normalized
        if let discoveryKeys, discoveryKeys != normalized.keys { refreshModels() }
    }

    func availableModels(including selections: [String]) -> [String] {
        var seen = Set<String>()
        return (discoveredModels + selections).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func refreshModels() {
        guard let keys = try? load().normalized.keys else { return }
        if keys == discoveryKeys, modelDiscovery != nil || !discoveredModels.isEmpty { return }
        modelDiscovery?.cancel()
        if keys != discoveryKeys { discoveredModels = [] }
        discoveryKeys = keys
        guard !keys.isEmpty else {
            modelDiscovery = nil
            return
        }
        modelDiscovery = Task { [weak self, client] in
            let models = await client.discoverModels(keys: keys)
            guard !Task.isCancelled, let self else { return }
            self.modelDiscovery = nil
            self.discoveredModels = models
        }
    }

    deinit { modelDiscovery?.cancel() }
}

@MainActor
final class WorkspaceChatController: ObservableObject {
    struct Activity: Identifiable {
        let id = UUID()
        let request: AIWorkspaceTool.Request
        var result: AIWorkspaceTool.Result?
        var failed = false
    }

    struct Turn: Identifiable {
        let id = UUID()
        let prompt: String
        let references: [AIChatReference]
        var answer = ""
        var reasoning = ""
        var activities: [Activity] = []
        var problem: String?
    }

    let workspace: AIWorkspace
    let settings: WorkspaceChatSettings
    private let client: OpenAIWorkspaceChat
    private let invoke: @Sendable (AIWorkspaceTool.Request) async throws -> AIWorkspaceTool.Result
    private var task: Task<Void, Never>?
    private var history: [AIChatMessage] = []
    private var nextReferenceID = 1

    @Published var draft = ""
    @Published var modelOverride: String?
    @Published var effortOverride: String?
    @Published private(set) var focusTick = 0
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var pendingReferences: [AIChatReference] = []
    @Published private(set) var referenceError: String?

    init(workspace: AIWorkspace, settings: WorkspaceChatSettings, client: OpenAIWorkspaceChat,
         invoke: @escaping @Sendable (AIWorkspaceTool.Request) async throws -> AIWorkspaceTool.Result) {
        self.workspace = workspace
        self.settings = settings
        self.client = client
        self.invoke = invoke
    }

    deinit { task?.cancel() }

    func addReferences(_ urls: [URL]) {
        referenceError = nil
        var seen = Set(pendingReferences.map(\.url))
        for url in urls {
            do {
                let reference = try AIChatReference(id: nextReferenceID, url: url)
                guard seen.insert(reference.url).inserted else { continue }
                pendingReferences.append(reference)
                nextReferenceID += 1
            } catch {
                if referenceError == nil { referenceError = "\(url.lastPathComponent) 无法添加 · \(error.localizedDescription)" }
            }
        }
    }

    func removeReference(_ id: Int) {
        pendingReferences.removeAll { $0.id == id }
        referenceError = nil
    }

    func copyDraft(from other: WorkspaceChatController) {
        draft = other.draft
        pendingReferences = other.pendingReferences
        nextReferenceID = other.nextReferenceID
        modelOverride = other.modelOverride
        effortOverride = other.effortOverride
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !prompt.isEmpty else { return }
        let turn = Turn(prompt: prompt, references: pendingReferences)
        turns.append(turn)
        let references = turns.flatMap(\.references)
        let requestPrompt = references.isEmpty ? prompt
            : prompt + "\n\n本会话的只读引用（本条消息新附加的引用列在最后）\n" + references.map(\.manifestEntry).joined(separator: "\n")
        draft = ""
        pendingReferences = []
        referenceError = nil
        running = true
        task = Task { [weak self, client, settings, history, invoke, modelOverride, effortOverride] in
            do {
                var configuration = try settings.load()
                if let modelOverride { configuration.model = modelOverride }
                if let effortOverride { configuration.effort = effortOverride }
                let answer = try await client.respond(settings: configuration, history: history, prompt: requestPrompt,
                    onEvent: { [weak self] event in await self?.receive(event, turnID: turn.id) },
                    invoke: { request in
                        guard AIChatReference.handles(request.path) else { return try await invoke(request) }
                        return try await runChatRead { try AIChatReference.invoke(request, references: references) }
                    })
                self?.finish(turnID: turn.id, answer: answer)
            } catch is CancellationError {
                self?.finish(turnID: turn.id, problem: "已停止")
            } catch {
                self?.finish(turnID: turn.id, problem: error.localizedDescription)
            }
        }
    }

    func preparePrompt(_ prompt: String) {
        draft = prompt
        focusTick += 1
    }

    func stop() {
        guard running else { return }
        stopping = true
        task?.cancel()
    }

    private func receive(_ event: OpenAIWorkspaceChat.Event, turnID: UUID) {
        guard let index = turns.indices.last, turns[index].id == turnID else { return }
        switch event {
        case .reason(let text): turns[index].reasoning += text
        case .text(let text): turns[index].answer += text
        case .toolStarted(let request): turns[index].activities.append(Activity(request: request))
        case .toolFinished(let request, let result, let failed):
            guard let activity = turns[index].activities.indices.last, turns[index].activities[activity].request == request else { return }
            turns[index].activities[activity].result = result
            turns[index].activities[activity].failed = failed
        }
    }

    private func finish(turnID: UUID, answer: String? = nil, problem: String? = nil) {
        guard let index = turns.indices.last, turns[index].id == turnID else { return }
        if let answer { turns[index].answer = answer }
        turns[index].problem = problem
        if answer != nil || !turns[index].answer.isEmpty || turns[index].activities.contains(where: { $0.result?.edited == true }) {
            history.append(.init(role: .user, text: turns[index].prompt))
            var context = turns[index].answer
            let files = turns[index].activities.filter { $0.result?.edited == true }.map { $0.request.path }
            if !files.isEmpty { context += "\n\n已修改的文件：\(files.joined(separator: "、"))" }
            if let problem { context += "\n\n本轮已结束（\(problem)）" }
            history.append(.init(role: .assistant, text: context))
            if history.count > 40 { history.removeFirst(history.count - 40) }
        }
        running = false
        stopping = false
        task = nil
    }
}

struct WorkspaceChatTab: Identifiable {
    let id: UUID
    let projectID: String
    let title: String
    let chat: WorkspaceChatController
}

extension ProjectSession {
    func invokeChatTool(_ request: AIWorkspaceTool.Request, workspace: AIWorkspace) async throws -> AIWorkspaceTool.Result {
        try Task.checkCancellation()
        guard workspace.root.path == project.root.path else { throw AIWorkspace.Problem.unsafePath }
        switch request {
        case .list(let path):
            return try await runChatRead {
                let entries = try workspace.list(path)
                return .init(summary: "列出 \(entries.count) 项", output: entries.isEmpty ? "目录为空" : entries.joined(separator: "\n"))
            }
        case .read(let path, let start, let count):
            return try await runChatRead {
                let text = try workspace.read(path, startLine: start, lineCount: count)
                return .init(summary: "已读取文件", output: text)
            }
        case .search(let path, let query):
            return try await runChatRead {
                let text = try workspace.search(query, under: path)
                return .init(summary: "已搜索 \(query.prefix(50))", output: text)
            }
        case .replace, .create:
            let url = try workspace.fileURL(for: request.path)
            await collectDraftForProjectSearch()
            try Task.checkCancellation()
            guard !isUndoing, !isRollingBack, !isSwitchingBranch, !isSyncingRemote, commit?.isCommitting != true else {
                throw ChatEditProblem("另一项文件或 Git 操作正在进行")
            }
            let targetIdentity = fileIdentity(url.path)
            let hasDraft = drafts.keys.contains { id in
                guard let draftURL = EditorTab.fileURL(fromID: id) else { return false }
                return draftURL.path == url.path || (targetIdentity != nil && targetIdentity == fileIdentity(draftURL.path))
            }
            guard !hasDraft else {
                throw ChatEditProblem("该文件有未保存的编辑，请保存后再试")
            }
            let edit: AIWorkspace.Edit
            switch request {
            case .replace(let path, let old, let new): edit = try workspace.replace(path, old: old, new: new)
            case .create(let path, let text): edit = try workspace.create(path, text: text)
            default: throw OpenAIWorkspaceChat.Failure.invalidArguments
            }
            if let before = edit.before {
                recordUndo("AI 编辑 \(edit.path)", .textChanges([.init(path: edit.path, before: before, after: edit.after)]))
            } else {
                recordUndo("AI 新建 \(edit.path)", .createFile(url: url, trashed: nil))
            }
            refreshAll()
            return .init(summary: edit.before == nil ? "已新建文件" : "已编辑文件", edited: true)
        }
    }
}

/// File reads run off the main actor and share the lifetime of the chat request.
private func runChatRead(
    _ read: @escaping @Sendable () throws -> AIWorkspaceTool.Result
) async throws -> AIWorkspaceTool.Result {
    try Task.checkCancellation()
    let worker = Task.detached(operation: read)
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
}

private struct ChatEditProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
