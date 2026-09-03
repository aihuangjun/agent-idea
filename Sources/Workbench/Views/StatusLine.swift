import DesignSystem
import SwiftUI

/// 工具窗口底部那一行操作结果：✓ 绿色成功 / ⚠ 红色失败，右边一个 × 关掉。提交面板与提交历史共用。
struct StatusLine: View {
    let status: OperationStatus
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            switch status {
            case .success(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(text).foregroundStyle(Theme.secondaryText)
            case .failure(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(text).foregroundStyle(Theme.text).textSelection(.enabled)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(Theme.mutedText)
        }
        .font(Theme.smallFont)
        .lineLimit(4)
    }
}
