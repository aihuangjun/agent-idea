import AppKit
import Core
import DesignSystem
import SwiftUI

/// 没打开项目时的欢迎页：最近项目 + 打开按钮。
struct WelcomeView: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    let openProject: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent IDEA").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Agent 开发配套的 IDEA：看工作区，看 Agent 改了什么")
                            .font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
                    }
                }
                Button(action: openProject) {
                    Label("打开项目…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                Text("也可以把目录拖进窗口，或者在终端里 `open -a AgentIDEA <目录>`")
                    .font(Theme.smallFont).foregroundStyle(Theme.mutedText)
                Spacer()
                Text("版本 \(BuildIdentity.current.display)").font(.system(size: 10)).foregroundStyle(Theme.mutedText)
            }
            .padding(28)
            .frame(width: 320)
            .background(Theme.panel)

            VStack(alignment: .leading, spacing: 0) {
                Text("最近项目").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                if workbench.recentProjects.isEmpty {
                    Text("还没有打开过项目").font(Theme.uiFont).foregroundStyle(Theme.mutedText).padding(.horizontal, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(workbench.recentProjects) { recent in RecentRow(recent: recent) }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.editorBackground)
        }
    }
}

private struct RecentRow: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    let recent: RecentProject
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.folderIcon).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name).font(Theme.uiFont).foregroundStyle(Theme.text)
                Text(recent.displayPath).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isHovering {
                Button { workbench.removeRecent(recent) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain).help("从列表移除")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? Theme.hover.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { workbench.openProject(recent.url) }
    }
}
