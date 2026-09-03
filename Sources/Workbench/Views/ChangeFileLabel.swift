import Core
import DesignSystem
import SwiftUI

/// 一条变更在列表里的样子：文件名（按种类着色，删除的划掉）、目录、重命名前的路径、右端的状态字。
/// 变更列表与提交历史的文件列表共用。图标、勾选框、缩进由各自的行负责。
struct ChangeFileLabel: View {
    let change: GitChange

    private var fileName: some View {
        Text(change.fileName)
            .font(Theme.uiFont)
            .foregroundStyle(VCSColors.color(for: change.kind))
            .strikethrough(change.kind == .deleted)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var secondaryTexts: some View {
        if !change.directory.isEmpty {
            Text(change.directory).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).fixedSize()
        }
        if let original = change.originalPath {
            Text("← \(original)").font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1).fixedSize()
        }
    }

    var body: some View {
        // 放得下就带目录名（和重命名前的路径），放不下就只留文件名——目录名被截成一两个字母比没有更难看
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                fileName
                secondaryTexts
            }
            fileName
        }
        Spacer(minLength: 4)
        // 状态字永远完整显示；空间不够时先截目录、再截文件名
        Text(change.kind.label)
            .font(.system(size: 10))
            .foregroundStyle(VCSColors.color(for: change.kind).opacity(0.85))
            .fixedSize()
            .layoutPriority(2)
    }
}
