import Core
import DesignSystem
import SwiftUI

struct JavaHierarchySheet: View {
    private enum Direction: String, CaseIterable { case callers = "调用者", callees = "被调用方法" }

    private struct Row: Identifiable {
        let id: [String]
        let node: JavaSemanticSearch.Location
        let site: JavaSemanticSearch.Location?
        let depth: Int
        let expandable: Bool
        let recursive: Bool
    }

    let session: ProjectSession
    let request: JavaHierarchyRequest
    @State private var direction = Direction.callers
    @State private var expanded: Set<[String]> = [[]]

    private var rows: [Row] {
        let edges = direction == .callers ? request.incoming : request.outgoing
        var rows: [Row] = []
        func append(_ node: JavaSemanticSearch.Location, site: JavaSemanticSearch.Location?, route: [String], ancestors: Set<String>) {
            guard rows.count < 1_000 else { return }
            let recursive = ancestors.contains(node.id)
            let children = edges[node.id, default: []]
            rows.append(Row(id: route, node: node, site: site, depth: route.count, expandable: !recursive && !children.isEmpty, recursive: recursive))
            guard !recursive, expanded.contains(route) else { return }
            let parent = ancestors.union([node.id])
            for edge in children {
                let other = direction == .callers ? edge.from : edge.to
                if let target = request.nodes[other] { append(target, site: edge.site, route: route + [edge.id], ancestors: parent) }
            }
        }
        append(request.root, site: nil, route: [], ancestors: [])
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("调用层级 · \(request.title)").font(.headline).lineLimit(2)
            Picker("方向", selection: $direction) {
                ForEach(Direction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if request.incomplete { Text("部分项目源码未能解析，结果可能不完整。").foregroundStyle(Theme.warning) }
            List(rows) { row in
                HStack(spacing: 7) {
                    if row.expandable {
                        Button {
                            if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                        } label: {
                            Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                                .frame(width: 16, height: 22)
                        }.buttonStyle(.borderless).accessibilityLabel(expanded.contains(row.id) ? "折叠" : "展开")
                    } else { Color.clear.frame(width: 16, height: 22) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.node.title + (row.recursive ? "（递归）" : "")).lineLimit(1)
                        let source = row.site ?? row.node
                        Text("\(source.path):\(source.line + 1)").font(Theme.smallFont).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    if let site = row.site { Button("调用处") { open(site) }.buttonStyle(.borderless) }
                    Button("声明") { open(row.node) }.buttonStyle(.borderless)
                }.padding(.leading, CGFloat(min(row.depth, 12)) * 17)
            }
            if rows.count == 1 { Text(direction == .callers ? "未找到项目内的调用者" : "未找到在项目内声明的被调用方法").foregroundStyle(Theme.secondaryText) }
            HStack {
                Spacer()
                Button("关闭") { session.javaHierarchy = nil; session.focusContent() }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(width: 660, height: 430)
            .onChange(of: direction) { expanded = [[]] }
    }

    private func open(_ location: JavaSemanticSearch.Location) {
        session.javaHierarchy = nil
        session.openDefinition(session.javaTarget(location), name: "")
    }
}
