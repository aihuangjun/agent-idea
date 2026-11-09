import DesignSystem
import SwiftUI

/// 跳到行（⌘L，IDEA 的 Go to Line）：`行` 或 `行:列`，回车跳过去、Esc 关掉。样子照文件内查找条。
struct GoToLineBar: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line").foregroundStyle(Theme.secondaryText)
            FocusedTextField(
                text: Binding(get: { session.goToLineText }, set: { session.setGoToLineText($0) }),
                placeholder: "跳到行：行 或 行:列", focusRequests: session.goToLineFocusRequests,
                onKey: { key in
                    switch key {
                    case .submit: session.submitGoToLine(); return true
                    case .cancel: session.closeGoToLine(); return true
                    case .up, .down: return false
                    }
                }
            )
            .frame(minWidth: 120, maxWidth: 220)
            if session.goToLineInvalid {
                Text("请输入行号，如 120 或 120:5").font(Theme.smallFont).foregroundStyle(Theme.warning).lineLimit(1)
            } else {
                Text("回车跳转，超出范围停在首 / 末行").font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1)
            }
            Spacer(minLength: 0)
            IconButton("xmark", help: "关闭（Esc）", size: 22) { session.closeGoToLine() }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.panel)
    }
}
