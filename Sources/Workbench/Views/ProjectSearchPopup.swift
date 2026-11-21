import Core
import DesignSystem
import SwiftUI

struct ProjectSearchPopup: View {
    let session: ProjectSession
    @ObservedObject var search: ProjectSearchController

    var body: some View {
        if search.isShown {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onPress { _ in session.closeProjectSearch() }
                panel.padding(.top, 48).padding(.horizontal, 12)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(ProjectSearch.Scope.allCases, id: \.self) { scope in
                    Button { search.scope = scope } label: {
                        Text(scope.title)
                            .font(Theme.smallFont.weight(search.scope == scope ? .semibold : .regular))
                            .foregroundStyle(search.scope == scope ? Theme.text : Theme.secondaryText)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(search.scope == scope ? Theme.selection : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(search.scope == scope ? .isSelected : [])
                }
                Spacer()
                if search.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text("正在索引").font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                FocusedTextField(text: $search.query, placeholder: search.scope.placeholder, focusRequests: search.focusRequests,
                                 onTab: search.cycleScope) { key in
                    switch key {
                    case .up: search.moveSelection(by: -1)
                    case .down: search.moveSelection(by: 1)
                    case .submit: if let result = search.selected { session.openProjectSearchResult(result) }
                    case .cancel: session.closeProjectSearch()
                    }
                    return true
                }
                .accessibilityLabel("全局搜索")
            }
            .padding(.horizontal, 9).frame(height: 29)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, lineWidth: 1))
            .padding(.horizontal, 10).padding(.bottom, 8)
            Rectangle().fill(Theme.border).frame(height: 1)
            resultsList
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                if search.incomplete, search.scope != .files {
                    Text("部分源码未能加入索引")
                }
                Spacer()
                Text("Tab 切换 · ↵ 打开 · Esc 关闭")
            }
            .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    @ViewBuilder private var resultsList: some View {
        if search.results.isEmpty {
            let emptyQuery = search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Text(emptyQuery ? "输入名称开始搜索" : search.isIndexing ? "正在查找…" : "没有匹配的结果")
                .font(Theme.uiFont).foregroundStyle(Theme.mutedText)
                .frame(maxWidth: .infinity).frame(height: 54)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(search.results.enumerated()), id: \.element.id) { index, result in
                            ProjectSearchRow(result: result, selected: index == search.selectedIndex,
                                             select: { search.select(index) }, open: { session.openProjectSearchResult(result) })
                                .id(result.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(340, CGFloat(search.results.count) * Theme.treeRowHeight + 8))
                .onChange(of: search.selected?.id) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }
}

private struct ProjectSearchRow: View {
    let result: ProjectSearch.Result
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var name: AttributedString {
        var text = AttributedString(result.name)
        for offset in result.matchedNameIndices where offset < text.characters.count {
            let start = text.index(text.startIndex, offsetByCharacters: offset)
            let end = text.index(start, offsetByCharacters: 1)
            text[start..<end].foregroundColor = Theme.accent
            text[start..<end].font = Theme.uiFont.weight(.semibold)
        }
        return text
    }

    private var icon: FileIcon.Descriptor {
        switch result.symbol?.kind {
        case .type: return .init(systemName: "square.stack.3d.up", color: Theme.accent)
        case .interface: return .init(systemName: "point.3.connected.trianglepath.dotted", color: Theme.accent)
        case .function: return .init(systemName: "function", color: Theme.accent)
        case .variable: return .init(systemName: "number", color: Theme.secondaryText)
        case nil: return FileIcon.file(named: result.name)
        }
    }

    var body: some View {
        let detail = result.symbol.map { symbol in
            let source = "\(result.path):\(symbol.line + 1)"
            let owner = String(symbol.qualifiedName.dropLast(symbol.name.count)).dropLast()
            return owner.isEmpty ? source : "\(owner) · \(source)"
        } ?? (result.path as NSString).deletingLastPathComponent
        HStack(spacing: 7) {
            Image(systemName: icon.systemName).font(.system(size: 12)).foregroundStyle(icon.color).frame(width: 17)
            Text(name).font(Theme.uiFont).foregroundStyle(Theme.text).lineLimit(1)
                .layoutPriority(1)
            if !detail.isEmpty {
                Text(detail).font(Theme.smallFont).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10).frame(height: Theme.treeRowHeight)
        .background(selected ? Theme.selection : hovering ? Theme.hover.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onPress { _ in select() } release: { clicked in if clicked { open() } }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { open() }
        .help(detail.isEmpty ? result.path : detail)
    }
}

private extension ProjectSearch.Scope {
    var title: String {
        switch self {
        case .all: return "全部"
        case .types: return "类"
        case .files: return "文件"
        case .symbols: return "符号"
        }
    }

    var placeholder: String {
        switch self {
        case .all: return "搜索类、文件和符号"
        case .types: return "搜索类名或接口名"
        case .files: return "搜索文件名或路径"
        case .symbols: return "搜索方法、函数和变量"
        }
    }
}
