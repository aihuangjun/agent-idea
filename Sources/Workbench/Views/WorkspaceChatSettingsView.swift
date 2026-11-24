import Core
import DesignSystem
import SwiftUI

/// KBReader's OpenAI settings section and its debounced save and per-key check behavior.
@MainActor
final class WorkspaceChatSettingsModel: ObservableObject {
    enum CheckState: Equatable {
        case running, passed(String), failed(String)
    }

    @Published var draft = AIChatSettings(keys: [""]) {
        didSet {
            guard loaded, draft != oldValue else { return }
            dirty = true
            scheduleSave()
            let oldKeys = oldValue.normalized.keys
            let keys = draft.normalized.keys
            if draft.model != oldValue.model || draft.effort != oldValue.effort {
                cancelChecks()
                checks = [:]
            } else if oldKeys != keys {
                for key in oldKeys where !keys.contains(key) {
                    checkTasks.removeValue(forKey: key)?.cancel()
                    checks[key] = nil
                }
            }
        }
    }
    @Published private(set) var loaded = false
    @Published private(set) var checks: [String: CheckState] = [:]
    @Published private(set) var saveError: String?

    private let controller: WorkspaceChatSettings
    private let client: OpenAIWorkspaceChat
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var checkTasks: [String: Task<Void, Never>] = [:]

    init(controller: WorkspaceChatSettings, client: OpenAIWorkspaceChat = .init()) {
        self.controller = controller
        self.client = client
    }

    func open() {
        if !loaded {
            do {
                var saved = try controller.load()
                if saved.keys.isEmpty { saved.keys = [""] }
                draft = saved
                loaded = true
                saveError = nil
            } catch { saveError = error.localizedDescription }
        }
        if loaded { controller.refreshModels() }
    }

    func close() {
        flush()
        cancelChecks()
        checks = checks.filter { $0.value != .running }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        do {
            try controller.save(draft)
            dirty = false
            saveError = nil
        } catch { saveError = "设置没存下去：\(error.localizedDescription)" }
    }

    func addOpenAIKey() { draft.keys.append("") }

    func removeOpenAIKey(at index: Int) {
        guard draft.keys.indices.contains(index) else { return }
        draft.keys.remove(at: index)
    }

    func checkOpenAI(key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, checks[key] != .running else { return }
        flush()
        checks[key] = .running
        let settings = AIChatSettings(model: draft.model, effort: draft.effort)
        checkTasks[key] = Task { [weak self, client] in
            let started = ContinuousClock.now
            let state: CheckState
            do {
                _ = try await client.checkConnection(settings: settings, key: key)
                let duration = started.duration(to: .now).formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
                state = .passed("连接正常（\(settings.model) · \(settings.effort)，\(duration)）")
            } catch { state = .failed(error.localizedDescription) }
            guard !Task.isCancelled, let self else { return }
            self.checkTasks[key] = nil
            self.checks[key] = state
        }
    }

    func checkAllOpenAIKeys() { draft.normalized.keys.forEach(checkOpenAI(key:)) }

    private func cancelChecks() {
        for task in checkTasks.values { task.cancel() }
        checkTasks.removeAll()
    }
}

@MainActor
struct WorkspaceChatSettingsView: View {
    @ObservedObject private var controller: WorkspaceChatSettings
    @StateObject private var model: WorkspaceChatSettingsModel

    init(controller: WorkspaceChatSettings) {
        self.controller = controller
        _model = StateObject(wrappedValue: WorkspaceChatSettingsModel(controller: controller))
    }

    var body: some View {
        Form {
            Section {
                ForEach(model.draft.keys.indices, id: \.self) { index in
                    keyRow(index)
                }
                HStack {
                    Button { model.addOpenAIKey() } label: { Label("添加 Key", systemImage: "plus") }
                    Spacer()
                    Button("全部测试", action: model.checkAllOpenAIKeys)
                        .disabled(model.draft.normalized.keys.isEmpty)
                }
            } header: {
                Text("OpenAI GPT · API Key")
            } footer: {
                Text("可以填多把：对话时按顺序用，一把额度用完或失效就自动换下一把。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("模型", selection: $model.draft.model) {
                    ForEach(controller.availableModels(including: [model.draft.model]), id: \.self) { Text($0).tag($0) }
                }
                Picker("Reasoning effort", selection: $model.draft.effort) {
                    ForEach(AIChatSettings.efforts, id: \.self) { Text($0).tag($0) }
                }
            }
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .disabled(!model.loaded)
        .frame(width: 540, height: 420)
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }

    private func keyRow(_ index: Int) -> some View {
        let keys = model.draft.keys
        let key = keys.indices.contains(index) ? keys[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let state = key.isEmpty ? nil : model.checks[key]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Key \(index + 1)").frame(width: 48, alignment: .leading)
                SecureField("Key \(index + 1)", text: keyBinding(index), prompt: Text("sk-…"))
                    .labelsHidden()
                Button("测试") { model.checkOpenAI(key: key) }
                    .disabled(key.isEmpty || state == .running)
                    .accessibilityIdentifier("ai-key-test-\(index + 1)")
                Button { model.removeOpenAIKey(at: index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("删掉这一把")
            }
            checkStatus(state)
        }
    }

    private func keyBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.draft.keys.indices.contains(index) ? model.draft.keys[index] : "" },
            set: { if model.draft.keys.indices.contains(index) { model.draft.keys[index] = $0 } }
        )
    }

    @ViewBuilder
    private func checkStatus(_ state: WorkspaceChatSettingsModel.CheckState?) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case let .passed(text):
            Text(text).font(.caption).foregroundStyle(Theme.success)
        case let .failed(text):
            Text(text).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
        }
    }
}
