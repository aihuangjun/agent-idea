import Core
import DesignSystem
import SwiftUI

/// 更新流程的对话框。自动检查只在真有新版本时露面；手动检查每个阶段都给反馈。
struct UpdateDialog: ViewModifier {
    @EnvironmentObject private var updater: Updater

    private var isPresented: Binding<Bool> {
        Binding(
            get: {
                switch updater.phase {
                case .idle: return false
                // 自动检查失败不打扰人：没网、没登录 gh、仓库里还没发过版本，都不该在启动时弹个框
                case .checking, .upToDate, .failed: return updater.isUserInitiated
                case .available, .downloading, .readyToRelaunch: return true
                }
            },
            set: { shown in if !shown { updater.dismiss() } }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            UpdateSheet()
                .environmentObject(updater)
        }
    }
}

private struct UpdateSheet: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.phase {
            case .idle:
                EmptyView()
            case .checking:
                header("正在检查更新…")
                ProgressView().controlSize(.small)
            case .upToDate:
                header("已经是最新版本")
                Text("当前版本 \(updater.build.display)").foregroundStyle(Theme.secondaryText)
                buttons { Button("好") { updater.dismiss() }.keyboardShortcut(.defaultAction) }
            case .available(let manifest):
                header("有新版本 \(manifest.version)")
                Text("当前 \(updater.currentVersion) · 安装包 \(manifest.displaySize)").foregroundStyle(Theme.secondaryText)
                if let notes = manifest.notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.editorBackground))
                }
                buttons {
                    Button("稍后") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("下载并安装") { updater.install(manifest) }.keyboardShortcut(.defaultAction)
                }
            case .downloading:
                header("正在下载并安装…")
                ProgressView().controlSize(.small)
                Text("下载完成后会替换应用，然后提示重启。").foregroundStyle(Theme.secondaryText)
            case .readyToRelaunch(let manifest):
                header("\(manifest.version) 已安装")
                Text("重启后生效。").foregroundStyle(Theme.secondaryText)
                buttons {
                    Button("稍后") { updater.dismiss() }
                    Button("立即重启") { updater.relaunch() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                header("更新失败")
                Text(message).font(.system(size: 12)).textSelection(.enabled)
                buttons { Button("关闭") { updater.dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}
