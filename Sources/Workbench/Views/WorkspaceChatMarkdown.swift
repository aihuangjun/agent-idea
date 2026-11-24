import AppKit
import Core
import DesignSystem
import SwiftUI

// KBReader Sources/AIChat/UI/ChatPanelView.swift: selectable Markdown, tables, and code cards.
struct ChatMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdownBlock.split(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .prose(prose):
                    Text(Self.attributed(prose))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(language, body):
                    CodeBlockView(language: language, code: body)
                case let .table(header, rows):
                    MarkdownTableView(header: header, rows: rows)
                case let .quote(quote):
                    Text(Self.attributed(quote))
                        .foregroundStyle(WorkspaceChatPalette.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(WorkspaceChatPalette.border).frame(width: 3)
                        }
                }
            }
        }
    }

    static func attributed(_ prose: String) -> AttributedString {
        let friendly = ChatMarkdownBlock.inlineFriendly(prose)
        var result = AttributedString()
        // 逐行：先交标准解析；解析完还露着 `**`（中文标点挨着 `**` 时它认不出收尾，见 `strongSegments`）
        // 才自己配对。顺序不能反：自己先配会拆坏 `[**文档**](url)`、`***x***` 这些标准写法。
        for (index, line) in friendly.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let standard = inline(String(line))
            guard String(standard.characters).contains("**"),
                  let segments = ChatMarkdownBlock.strongSegments(String(line))
            else {
                result += standard
                continue
            }
            for segment in segments {
                var piece = inline(segment.text)
                if segment.strong {
                    for run in piece.runs {
                        var intent = run.inlinePresentationIntent ?? []
                        intent.insert(.stronglyEmphasized)
                        piece[run.range].inlinePresentationIntent = intent
                    }
                }
                result += piece
            }
        }
        return result
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs {
            if let link = run.link, !["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                result[run.range].link = nil
            }
        }
        return result
    }
}

/// Markdown 表格：表头加粗、行间细线、外圈圆角描边；列多了横向滚动（Codex 的样子）。
///
/// **每列宽度先量好再交给格子**（`columnWidths`）：表格在横向 ScrollView 里，格子拿到的宽度提议是 nil，
/// `frame(maxWidth:)` 只把**画出来的宽**压到 180，高度却按单行算——长句折成三行，行高还是一行，
/// 压到下一行上（用户验收截图：「文字重叠，完全看不清」）。给了明确宽度，Text 才按折行后的高度报尺寸。
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    static let maxColumnWidth: CGFloat = 180
    static let cellFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize)

    var body: some View {
        let widths = Self.columnWidths(header: header, rows: rows)
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        cellView(cell, width: widths[index]).font(.callout.weight(.semibold))
                    }
                }
                .background(Color.primary.opacity(0.04))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, width: widths[min(index, widths.count - 1)]).font(.callout)
                        }
                    }
                }
            }
            .fixedSize()
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspaceChatPalette.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 每列：这一列里最宽那格排成一行要多宽，封顶 180（长句在格子里折行，而不是把整张表拉成一长条）。
    /// 量的是去掉 `**`、反引号之后的文字，全按加粗量；宁宽勿窄，多留 2pt。
    static func columnWidths(header: [String], rows: [[String]]) -> [CGFloat] {
        let bold = NSFont.systemFont(ofSize: cellFont.pointSize, weight: .semibold)
        return header.indices.map { column in
            // 一律按加粗量：格子里的 `**短标签**` 按常规字重量会窄一截，被折成两行。宁宽勿窄。
            let cells = [header[column]] + rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
            let widest = cells.map { text in
                let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                return ceil((plain as NSString).size(withAttributes: [.font: bold]).width) + 2
            }.max() ?? 0
            return min(max(widest, 24), maxColumnWidth)
        }
    }

    private func cellView(_ text: String, width: CGFloat) -> some View {
        Text(ChatMarkdownText.attributed(text))
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(WorkspaceChatPalette.secondaryText)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(WorkspaceChatPalette.secondaryText)
                .toolTip("复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.03))
            Divider()
            // 横向 ScrollView 不按内容定高：不钉住的话多行代码被压成一行、尾巴变「…」（实测）。
            // 文字按理想尺寸排（不折行、不截断），ScrollView 竖向取内容的理想高度。
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 与表格同一套「内容卡片」：描边圆角，标题栏比正文深一档（过程行是另一套：浅底、无描边）。
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspaceChatPalette.border))
    }
}
