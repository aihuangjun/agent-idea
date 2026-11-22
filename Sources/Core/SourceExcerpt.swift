import Foundation

public enum SourceExcerpt {
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
    }

    /// 从声明前两行开始，在弹窗中保留足够的后文读短函数。
    public static func lines(in text: String, at line: Int) -> [Line] {
        guard line >= 0 else { return [] }
        let lines = LineEnding.normalized(text).components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return [] }
        return (max(0, line - 2)..<min(lines.count, line + 14)).map { index in
            Line(id: index, text: String(lines[index].prefix(800)))
        }
    }
}
