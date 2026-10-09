import Core
import DesignSystem
import SwiftUI

/// 底部的「运行」工具窗口（IDEA 的 Run）：标题条是在跑的脚本和状态，下面是输出。
struct RunToolWindow: View {
    @EnvironmentObject private var workbench: WorkbenchModel
    @ObservedObject var run: RunController
    let session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowHeader(title: "运行", detail: { status }) {
                IconButton(ToolWindowIcon.rerun, help: "重新运行（⌃R）", size: 22) { rerun() }
                    .disabled(!run.canRerun)
                IconButton(ToolWindowIcon.stop, help: "停止（⌘F2）", size: 22) { run.stop() }
                    .disabled(!run.isRunning)
                IconButton(ToolWindowIcon.clear, help: "清空输出", size: 22) { run.clear() }
                    .disabled(run.buffer.isEmpty)
                IconButton(ToolWindowIcon.hide, help: "收起（⌘4）", size: 22) { workbench.isRunWindowShown = false }
            }
            if run.buffer.isEmpty, run.script == nil {
                ToolWindowEmptyState(title: "还没有运行过脚本",
                                     detail: "在目录树或标签上右键 .py / .sh 文件 →「运行」，输出显示在这里")
            } else {
                ConsoleView(buffer: run.buffer)
                    .background(Theme.editorBackground)
            }
        }
        .background(Theme.editorBackground)
    }

    /// 标题后面：脚本名 + 在跑 / 退出码。
    private var status: some View {
        HStack(spacing: 6) {
            if run.script != nil {
                Text(run.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                if run.isRunning {
                    ProgressView().controlSize(.mini)
                    Text("运行中").font(Theme.smallFont).foregroundStyle(Theme.secondaryText)
                } else if let status = run.exitStatus {
                    Text("退出码 \(status)").font(Theme.smallFont)
                        .foregroundStyle(status == 0 ? Theme.secondaryText : Theme.danger)
                }
            }
        }
    }

    private func rerun() {
        guard let script = run.script else { return }
        session.runScript(script)
    }
}
