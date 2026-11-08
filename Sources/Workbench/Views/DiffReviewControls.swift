import Core
import DesignSystem
import SwiftUI

/// 阅读规则与当前位置放在一起；文件顺序由会话提供，变更块位置由同一份比较结果提供。
struct DiffReviewControls: View {
    @ObservedObject var preferences: ReadingPreferences
    let progress: DiffReviewProgress
    let supported: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("文件 \(progress.fileIndex)/\(progress.fileCount) · 变更 \(progress.changeIndex)/\(progress.changeCount)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.mutedText)
                .fixedSize()
            Menu {
                Toggle("折叠未修改区域", isOn: $preferences.diffReading.collapseUnchanged)
                Picker("保留上下文", selection: $preferences.diffReading.contextLines) {
                    ForEach(DiffReadingOptions.contextLineChoices, id: \.self) { Text("\($0) 行").tag($0) }
                }
                Divider()
                Picker("空白差异", selection: $preferences.diffReading.whitespace) {
                    ForEach(DiffWhitespaceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: preferences.diffReading.whitespace == .none ? "slider.horizontal.3" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Diff 阅读设置")
            .frame(width: 22)
            .disabled(!supported)
            .help(supported ? "Diff 阅读设置：折叠、上下文与空白差异。当前：\(preferences.diffReading.whitespace.label)" : "当前显示补丁；全文不可用，无法展开补丁之外的上下文")
        }
    }
}
