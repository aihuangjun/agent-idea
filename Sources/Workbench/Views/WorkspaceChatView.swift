import AppKit
import Core
import DesignSystem
import SwiftUI

/// KBReader's chat palette in light appearance, with Agent IDEA's dark surfaces.
enum WorkspaceChatPalette {
    static let accent = Color(hex: 0x4F46E5)
    static let background = color(0xF8FAFC, dark: ThemePalette.dark.editorBackground)
    static let surface = color(0xFFFFFF, dark: ThemePalette.dark.panel)
    static let border = color(0xE2E8F0, dark: ThemePalette.dark.border)
    static let secondaryText = color(0x64748B, dark: ThemePalette.dark.secondaryText)

    private static func color(_ light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

/// KBReader's right-edge drawer, overlaid on the workbench without changing the editor's bounds.
struct WorkspaceChatOverlay: View {
    @ObservedObject var workbench: WorkbenchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if workbench.isChatPresented, let tab = workbench.activeChat {
                let windowWidth = Double(geometry.size.width)
                let range = ChatPanelLayout.range(windowWidth: windowWidth)
                let width = Binding<CGFloat>(
                    get: { return CGFloat(ChatPanelLayout.clamp(Double(workbench.chatDrawerWidth), windowWidth: windowWidth)) },
                    set: { workbench.chatDrawerWidth = $0 }
                )
                HStack(spacing: 0) {
                    ResizeHandle(width: width, range: CGFloat(range.lowerBound)...CGFloat(range.upperBound), growsLeftward: true)
                    WorkspaceChatDrawer(workbench: workbench, tab: tab)
                        .frame(width: width.wrappedValue)
                }
                .shadow(color: .black.opacity(0.12), radius: 12, x: -4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: workbench.isChatPresented)
    }
}

/// Ported from KBReader ChatToggleButton, with the workbench's tooltip implementation.
struct WorkspaceChatToggle: View {
    @ObservedObject var workbench: WorkbenchModel

    var body: some View {
        let title = workbench.isChatPresented ? "隐藏 AI 对话" : "显示 AI 对话"
        Button { workbench.toggleAIChat() } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 10))
                Text("AI").font(.caption)
            }
            .foregroundStyle(workbench.isChatPresented ? WorkspaceChatPalette.accent : WorkspaceChatPalette.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolTip("\(title)（⌘J）")
        .accessibilityIdentifier("ai-chat-toggle")
        .accessibilityLabel(title)
    }
}

private struct WorkspaceChatDrawer: View {
    @ObservedObject var workbench: WorkbenchModel
    let tab: WorkspaceChatTab
    @State private var isReferenceDropTarget = false

    var body: some View {
        WorkspaceChatDropHost(content: contents, add: tab.chat.addReferences) { isReferenceDropTarget = $0 }
            .frame(maxHeight: .infinity)
            .overlay {
                if isReferenceDropTarget {
                    Rectangle().strokeBorder(WorkspaceChatPalette.accent, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier("ai-chat-panel")
    }

    private var contents: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("AI 对话").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                NewSessionButton { workbench.newAIChat() }
                    .accessibilityIdentifier("ai-chat-new-session")
                HeaderIconButton(symbol: "xmark", help: "隐藏 AI 对话（⌘J）") { workbench.isChatPresented = false }
                    .accessibilityIdentifier("ai-chat-close")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            Divider()
            if workbench.chatTabs.count > 1 {
                sessionTabs
                Divider()
            }
            WorkspaceChatView(chat: tab.chat, settings: workbench.chatSettings, currentFile: workbench.aiChatCurrentFile(tab),
                              projectID: tab.projectID, projects: workbench.sessions, selectProject: workbench.selectAIChatWorkspace,
                              openFile: { workbench.openAIChatFile($0, in: tab) })
                .id(tab.id)
        }
        .background(WorkspaceChatPalette.background)
        .foregroundStyle(Theme.text)
        .tint(WorkspaceChatPalette.accent)
    }

    private var sessionTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workbench.chatTabs) { item in
                        let selected = item.id == tab.id
                        HStack(spacing: 4) {
                            Button { workbench.selectAIChat(item.id) } label: {
                                Text(item.title).font(.caption.weight(selected ? .semibold : .regular))
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 130)
                                    .padding(.leading, 8).padding(.vertical, 5)
                                    .contentShape(Rectangle())
                            }
                            .foregroundStyle(selected ? WorkspaceChatPalette.accent : WorkspaceChatPalette.secondaryText)
                            .toolTip(item.chat.workspace.root.path)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            Button { workbench.closeAIChat(item.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).padding(5)
                            }
                            .foregroundStyle(WorkspaceChatPalette.secondaryText)
                            .accessibilityLabel("关闭 \(item.title)")
                        }
                        .buttonStyle(.plain)
                        .background(selected ? WorkspaceChatPalette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .onChange(of: tab.id, initial: true) { _, id in proxy.scrollTo(id) }
        }
        .frame(height: 34)
        .accessibilityIdentifier("ai-chat-tabs")
    }
}

/// The transcript and footer follow KBReader's ChatPanelView and ChatComposer.
private struct WorkspaceChatView: View {
    @ObservedObject var chat: WorkspaceChatController
    @ObservedObject var settings: WorkspaceChatSettings
    let currentFile: String?
    let projectID: String
    let projects: [ProjectSession]
    let selectProject: (String) -> Void
    let openFile: (String) -> Void
    @State private var inputHeight: CGFloat = 20

    private var model: String { chat.modelOverride ?? settings.settings?.model ?? AIChatSettings.defaultModel }
    private var effort: String { chat.effortOverride ?? settings.settings?.effort ?? AIChatSettings.defaultEffort }
    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if chat.turns.isEmpty {
                            ChatEmptyState(chat: chat, currentFile: currentFile)
                        }
                        ForEach(chat.turns) { turn in turnView(turn) }
                        Color.clear.frame(height: 1).id("ai-chat-bottom")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 14)
                }
                .defaultScrollAnchor(chat.turns.isEmpty ? .top : .bottom)
                .onChange(of: chat.turns.count) { _, _ in proxy.scrollTo("ai-chat-bottom", anchor: .bottom) }
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { settings.refreshModels() }
    }

    private func turnView(_ turn: WorkspaceChatController.Turn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(turn.references) { reference in referenceLabel(reference) }
                    Text(turn.prompt).textSelection(.enabled)
                }
                    .padding(.horizontal, Bubble.padding)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: BubbleShape(tail: .trailing))
            }
            HStack(alignment: .top, spacing: 8) {
                AssistantAvatar()
                VStack(alignment: .leading, spacing: 10) {
                    if !turn.reasoning.isEmpty {
                        ActivityRow(symbol: "sparkle", title: "思考摘要", summary: "") {
                            ActivityDetailText(text: turn.reasoning, monospaced: false)
                        }
                    }
                    ForEach(turn.activities) { activity in activityRow(activity) }
                    if !turn.answer.isEmpty { ChatMarkdownText(text: turn.answer) }
                    if chat.running, chat.turns.last?.id == turn.id, turn.answer.isEmpty, turn.activities.allSatisfy({ $0.result != nil }) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).frame(width: 14)
                            Text(chat.stopping ? "正在停止…" : (turn.activities.isEmpty ? "思考中…" : "继续中…"))
                        }
                        .font(.caption).foregroundStyle(WorkspaceChatPalette.secondaryText).frame(height: 28)
                    }
                    if let problem = turn.problem {
                        Label(problem, systemImage: problem == "已停止" ? "stop.circle" : "exclamationmark.circle")
                            .font(.caption).foregroundStyle(problem == "已停止" ? WorkspaceChatPalette.secondaryText : Theme.danger)
                            .textSelection(.enabled)
                    }
                    if !turn.answer.isEmpty, !chat.running || chat.turns.last?.id != turn.id {
                        Button { Desktop.copyToClipboard(turn.answer) } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(WorkspaceChatPalette.secondaryText)
                        .toolTip("复制回答")
                    }
                }
                .padding(Bubble.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceChatPalette.surface, in: BubbleShape(tail: .leading))
                .overlay(BubbleShape(tail: .leading).stroke(WorkspaceChatPalette.border))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
            }
        }
    }

    private func activityRow(_ activity: WorkspaceChatController.Activity) -> some View {
        let symbol: String = switch activity.request.tool {
        case .listFiles: "folder"
        case .readFile: "doc.text"
        case .searchText: "magnifyingglass"
        case .replaceText: "pencil"
        case .createFile: "doc.badge.plus"
        }
        return ActivityRow(symbol: symbol, title: activity.request.tool.label,
                           summary: activity.request.path, monospacedSummary: true,
                           isRunning: activity.result == nil && chat.running, failed: activity.failed,
                           initiallyExpanded: activity.failed) {
            if let result = activity.result {
                ActivityDetailText(text: result.summary, monospaced: false)
                if result.edited {
                    Button("打开文件") { openFile(activity.request.path) }
                        .buttonStyle(.plain).foregroundStyle(WorkspaceChatPalette.accent).font(.caption)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.pendingReferences.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(chat.pendingReferences) { reference in
                            HStack(spacing: 5) {
                                referenceLabel(reference)
                                Button { chat.removeReference(reference.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除引用 \(reference.name)")
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let error = chat.referenceError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
            WorkspaceChatInput(text: $chat.draft, height: $inputHeight,
                               placeholder: "给 AI 发消息…", focusTick: chat.focusTick,
                               onSubmit: chat.send, onEscape: {
                guard chat.running else { return false }
                chat.stop()
                return true
            }, addReferences: chat.addReferences)
            .frame(height: inputHeight)
            HStack(spacing: 5) {
                Button {
                    Desktop.chooseChatReferences(startingAt: chat.workspace.root, completion: chat.addReferences)
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WorkspaceChatPalette.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .toolTip("添加文件或文件夹")
                .accessibilityLabel("添加文件或文件夹")
                .accessibilityIdentifier("ai-chat-add-reference")
                scopeMenu
                Spacer(minLength: 2)
                modelMenu
                effortMenu
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(WorkspaceChatPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WorkspaceChatPalette.border).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
    }

    private func referenceLabel(_ reference: AIChatReference) -> some View {
        Label(reference.name, systemImage: reference.isDirectory ? "folder" : "doc")
            .font(.caption)
            .foregroundStyle(WorkspaceChatPalette.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .toolTip(reference.url.path)
    }

    private var scopeMenu: some View {
        Menu {
            Picker("项目空间", selection: Binding(get: { projectID }, set: selectProject)) {
                ForEach(projects) { session in
                    Text(session.project.root.path.abbreviatingHomeDirectory).tag(session.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(chat.workspace.root.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .foregroundStyle(WorkspaceChatPalette.secondaryText)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .toolTip(chat.workspace.root.path)
        .accessibilityLabel("项目空间 \(chat.workspace.root.path.abbreviatingHomeDirectory)")
        .accessibilityIdentifier("ai-chat-workspace")
    }

    private var modelMenu: some View {
        let defaultModel = settings.settings?.model ?? AIChatSettings.defaultModel
        let choices = settings.availableModels(including: [defaultModel, model])
        return Menu {
            Picker("模型", selection: Binding(get: { model }, set: { chat.modelOverride = $0 == defaultModel ? nil : $0 })) {
                ForEach(choices, id: \.self) { name in
                    Text(name == defaultModel ? "\(name)（默认）" : name).tag(name)
                }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsLink { Text("设置…") }
        } label: { menuLabel(model) }
        .modifier(CaptionMenu(help: "本对话使用的模型", id: "ai-chat-model"))
    }

    private var effortMenu: some View {
        let defaultEffort = settings.settings?.effort ?? AIChatSettings.defaultEffort
        return Menu {
            ForEach(AIChatSettings.efforts, id: \.self) { level in
                Button(level == defaultEffort ? "\(level)（默认）" : level) { chat.effortOverride = level == defaultEffort ? nil : level }
            }
        } label: { menuLabel(effort) }
        .modifier(CaptionMenu(help: "本对话使用的推理档位", id: "ai-chat-effort"))
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.caption).foregroundStyle(WorkspaceChatPalette.secondaryText)
        .padding(.horizontal, 5).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var sendButton: some View {
        if chat.running {
            Button { chat.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 26, height: 26)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain).disabled(chat.stopping)
            .toolTip("停止（Esc）")
            .accessibilityIdentifier("ai-chat-stop").accessibilityLabel("停止")
        } else {
            Button { chat.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 26, height: 26)
                    .background(canSend ? Color.primary : Color.primary.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain).disabled(!canSend)
            .toolTip("发送（回车；⇧↩ 换行）")
            .accessibilityIdentifier("ai-chat-send").accessibilityLabel("发送")
        }
    }
}

// The remaining small controls are ported from KBReader's ChatPanelView and ChatComposer.
private struct CaptionMenu: ViewModifier {
    let help: String
    let id: String

    func body(content: Content) -> some View {
        content.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize().toolTip(help).accessibilityIdentifier(id)
    }
}

private struct ChatEmptyState: View {
    @ObservedObject var chat: WorkspaceChatController
    let currentFile: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(WorkspaceChatPalette.accent.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("有什么可以帮你？").font(.system(size: 17, weight: .semibold))
            Text("在 \(chat.workspace.root.lastPathComponent) 中搜索、阅读和编辑项目文件。")
                .font(.callout).foregroundStyle(WorkspaceChatPalette.secondaryText).multilineTextAlignment(.center)
            VStack(spacing: 6) {
                if let currentFile {
                    starter("doc.text.magnifyingglass", "总结当前文件的要点", draft: "总结当前文件 \(currentFile) 的要点。")
                } else {
                    starter("doc.text.magnifyingglass", "阅读项目说明", draft: "请阅读当前项目的说明文件并总结要点。")
                }
                starter("rectangle.3.group", "了解项目结构", draft: "请查看这个项目的目录和说明，概括主要模块和入口。")
                starter("magnifyingglass", "在项目中搜索…", draft: "请在这个项目里搜索 ")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 8)
    }

    private func starter(_ symbol: String, _ title: String, draft: String) -> some View {
        Button { chat.preparePrompt(draft) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.caption).foregroundStyle(WorkspaceChatPalette.secondaryText).frame(width: 16)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 280)
            .background(WorkspaceChatPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WorkspaceChatPalette.border).allowsHitTesting(false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
