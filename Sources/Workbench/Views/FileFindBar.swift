import AppKit
import DesignSystem
import SwiftUI

struct FileFindBar: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
            FocusedTextField(text: $session.findQuery, placeholder: "在当前文件中查找", focusRequests: session.findFocusRequests, onKey: { key in
                switch key {
                case .submit: session.findInFile(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false); return true
                case .down: session.findInFile(); return true
                case .up: session.findInFile(backwards: true); return true
                case .cancel: session.closeFind(); return true
                }
            })
            .frame(minWidth: 120, maxWidth: 320)
            Toggle("区分大小写", isOn: $session.findCaseSensitive)
                .toggleStyle(.checkbox).font(Theme.smallFont)
            if !session.findQuery.isEmpty, let found = session.findFound {
                Text(found ? "已找到" : "未找到")
                    .font(Theme.smallFont).foregroundStyle(found ? Theme.secondaryText : Theme.warning)
            }
            IconButton("chevron.up", help: "上一个（↑）", size: 22) { session.findInFile(backwards: true) }
            IconButton("chevron.down", help: "下一个（回车 / ↓）", size: 22) { session.findInFile() }
            Spacer(minLength: 0)
            IconButton("xmark", help: "关闭查找（Esc）", size: 22) { session.closeFind() }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.panel)
        .onChange(of: session.findQuery) { _, _ in session.findInFile() }
        .onChange(of: session.findCaseSensitive) { _, _ in session.findInFile() }
    }
}
