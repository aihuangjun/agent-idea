import Core
import DesignSystem
import SwiftUI

/// 分支弹窗（IDEA 的 Git Branches）：状态栏的分支名、Git → 分支… 打开。
/// 顶上搜索、「新建分支…」（默认从 origin/master 开），下面本地分支、远程分支（默认分支排第一、标「默认」）。
/// 点一下就签出；右键可以「从这里新建分支…」。
struct BranchPopup: View {
    @ObservedObject var session: ProjectSession
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                FocusedTextField(text: $filter, placeholder: "搜索分支") { key in
                    switch key {
                    case .submit:
                        // 没输入就回车什么都不做：不然一个回车就切到了列表里第一个分支
                        if !filter.trimmingCharacters(in: .whitespaces).isEmpty, let first = matches.first { first.action() }
                    case .cancel:
                        session.isBranchPopupShown = false
                    default:
                        return false
                    }
                    return true
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
            .padding(8)

            BranchPopupRow(title: "新建分支…", detail: session.defaultNewBranchBase.map { "从 \($0)" }, systemImage: "plus", isEnabled: session.canSwitchBranch) {
                requestNewBranch(from: session.defaultNewBranchBase)
            }
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)

            if let list = session.branchList {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("本地分支", entries(list).filter { !$0.isRemote })
                        section("远程分支", entries(list).filter(\.isRemote))
                        if matches.isEmpty {
                            Text(filter.isEmpty ? "没有分支" : "没有匹配的分支").font(Theme.smallFont).foregroundStyle(Theme.mutedText).padding(10)
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(16)
            }
        }
        .padding(.bottom, 6)
        .frame(width: 340)
        .frame(maxHeight: 460)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Entry]) -> some View {
        let shown = items.filter(matchesFilter)
        if !shown.isEmpty {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedText)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            ForEach(shown) { entry in
                BranchPopupRow(title: entry.name, detail: entry.detail, systemImage: entry.systemImage, isCurrent: entry.isCurrent,
                               isEnabled: session.canSwitchBranch, action: entry.action)
                    .contextMenu {
                        if !entry.isCurrent { Button("签出") { entry.action() } }
                        Button("从 \(entry.name) 新建分支…") { requestNewBranch(from: entry.name) }
                    }
            }
        }
    }

    /// 弹窗里的一行。
    private struct Entry: Identifiable {
        var id: String { (isRemote ? "remote:" : "local:") + name }
        let name: String
        let detail: String?
        let isRemote: Bool
        let isCurrent: Bool
        let systemImage: String
        let action: () -> Void
    }

    private func entries(_ list: GitBranchList) -> [Entry] {
        let local = list.local.map { branch in
            Entry(name: branch.name, detail: branch.upstream.map { "→ \($0)" } ?? "没有上游", isRemote: false, isCurrent: branch.isCurrent,
                  systemImage: branch.isCurrent ? "checkmark" : "arrow.triangle.branch") {
                session.checkout(branch)
            }
        }
        let remote = list.remote.map { name in
            // 签出远程分支 = 切到同名本地分支（已有的话），否则建一个跟踪它的
            let localName = list.localName(for: name)
            var details: [String] = []
            if name == list.defaultRemoteBranch { details.append("默认") }
            if list.local(named: localName) != nil { details.append("本地：\(localName)") }
            return Entry(name: name, detail: details.isEmpty ? nil : details.joined(separator: " · "), isRemote: true, isCurrent: false,
                         systemImage: "cloud") {
                session.checkout(remote: name)
            }
        }
        return local + remote
    }

    private var matches: [Entry] {
        guard let list = session.branchList else { return [] }
        return entries(list).filter { !$0.isCurrent && matchesFilter($0) }
    }

    private func matchesFilter(_ entry: Entry) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || entry.name.localizedCaseInsensitiveContains(query)
    }

    /// 新建分支的对话框挂在状态栏上而不是弹窗里：弹窗一关，挂在里面的 sheet 也跟着没了。先关弹窗，下一轮再开对话框。
    private func requestNewBranch(from base: String?) {
        guard let base else { return }
        session.isBranchPopupShown = false
        DispatchQueue.main.async { session.newBranchRequest = NewBranchRequest(base: base) }
    }
}

private struct BranchPopupRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    var isCurrent = false
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(isCurrent ? Theme.accent : Theme.secondaryText).frame(width: 16)
                Text(title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(Theme.smallFont).foregroundStyle(Theme.mutedText).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.treeRowHeight + 2)
            .background(Rectangle().fill(isHovering && isEnabled && !isCurrent ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 当前分支那一行点了什么都不做（签出当前分支是空操作），但别用 disabled：那会把它画灰，而它该是最醒目的一行；
        // 也别关 hit testing：它的右键菜单里还有「从它新建分支…」
        .disabled(!isEnabled && !isCurrent)
        .opacity(isEnabled || isCurrent ? 1 : 0.5)
        .onHover { isHovering = $0 }
    }
}

/// 新建分支（IDEA 的 New Branch）：起点默认是远程的默认分支（origin/master），可以换；建好就切过去。
struct NewBranchSheet: View {
    @ObservedObject var session: ProjectSession
    @State var base: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var problem: GitBranchName.Problem? { session.newBranchProblem(name) }
    private var bases: [String] {
        let list = session.branchList
        var all = (list?.remote ?? []) + (list?.local.map(\.name) ?? [])
        if !all.contains(base) { all.insert(base, at: 0) }
        return all
    }
    private var tracksBase: Bool { session.branchList?.remote.contains(base) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建分支").font(.system(size: 15, weight: .semibold))
            FocusedTextField(text: $name, placeholder: "分支名，例如 feat/xxx") { key in
                switch key {
                case .submit: submit()
                case .cancel: dismiss()
                default: return false
                }
                return true
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, lineWidth: 1))
            Text(problem.flatMap { $0 == .empty ? nil : $0.message } ?? " ")
                .font(Theme.smallFont).foregroundStyle(Theme.danger)
            HStack {
                Text("从").foregroundStyle(Theme.secondaryText)
                Picker("", selection: $base) {
                    ForEach(bases, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            Text(tracksBase
                 ? "新分支会跟踪 \(base)：以后点「与远程同步」就把 \(base) 上的新提交 rebase 进来；推送推到远端的同名分支。没提交的改动会带到新分支上。"
                 : "新分支没有上游：第一次推送时建立。没提交的改动会带到新分支上。")
                .font(Theme.smallFont).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建并切换") { submit() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
    }

    private func submit() {
        guard problem == nil else { return }
        dismiss()
        session.createBranch(named: name, from: base)
    }
}
