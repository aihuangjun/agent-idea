import Core
import DesignSystem
import SwiftUI

struct SourceNavigationPicker: View {
    let session: ProjectSession
    let request: SourceNavigationRequest
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var focused: Bool

    private var entries: [SourceNavigationEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return request.entries }
        let entries = request.entries.map { entry in
            FileSearchEntry(path: entry.detail + "/" + entry.title)
        }
        let matches = Set(FileSearch.search(query, in: entries, limit: entries.count).map(\.entry.path))
        return zip(request.entries, entries).compactMap { entry, candidate in
            matches.contains(candidate.path) || entry.detail.localizedCaseInsensitiveContains(query) ? entry : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            TextField(request.placeholder, text: $query)
                .focused($focused)
                .onSubmit(openSelected)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
            if entries.isEmpty { Text(query.isEmpty ? "没有可显示的位置" : "没有匹配的位置").foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .id(entry.id)
                    .tag(entry.id)
                }
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("跳转", action: openSelected).keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 480, height: 360)
        .onAppear {
            selection = request.preferredIndex.flatMap { request.entries.indices.contains($0) ? request.entries[$0].id : nil }
                ?? request.entries.first?.id
            focused = true
        }
        .onChange(of: query) { selection = entries.first?.id }
    }

    private func move(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selection } ?? 0
        selection = entries[min(max(index + offset, 0), entries.count - 1)].id
    }

    private func openSelected() {
        guard let entry = entries.first(where: { $0.id == selection }) else { return }
        session.sourceNavigation = nil
        session.openLocation(entry.point)
        session.focusContent()
    }

    private func close() {
        session.sourceNavigation = nil
        session.focusContent()
    }
}
