import Core
import Foundation

/// 编辑器里改了还没保存的文本（草稿），以及围绕它的判定与写盘。
///
/// 纯值类型，不认识渲染器、标签栏和 git：什么时候向编辑器要文字、写完要不要刷 git，是 `ProjectSession` 的事。
/// 键是标签 id。有草稿 = 「已修改」；与磁盘上读进来的一致就删掉草稿。
struct DraftStore: Equatable {
    /// 能在编辑器里改的上限。再大的文件 CodeMirror 会卡，只读着看。
    static let editableLimit = 2 << 20

    private(set) var drafts: [String: String] = [:]

    var isEmpty: Bool { drafts.isEmpty }
    subscript(id: String) -> String? { drafts[id] }
    func isModified(_ id: String) -> Bool { drafts[id] != nil }

    /// 这份内容能不能编辑：是文本、不太大。
    static func isEditable(_ content: TabContent?) -> Bool {
        guard let text = content?.text else { return false }
        return text.utf8.count <= editableLimit
    }

    /// 编辑器送来的文字。与读进来的一样（行尾归一后比）就不算改动。返回现在是否有草稿。
    @discardableResult
    mutating func apply(text: String, to id: String, saved: String) -> Bool {
        if LineEnding.normalized(text) == LineEnding.normalized(saved) {
            drafts[id] = nil
            return false
        }
        drafts[id] = text
        return true
    }

    mutating func discard(_ id: String) {
        drafts[id] = nil
    }

    /// 文件改了名：草稿跟着换键。
    mutating func move(_ id: String, to newID: String) {
        guard let draft = drafts.removeValue(forKey: id) else { return }
        drafts[newID] = draft
    }

    /// 把一个标签的草稿写回磁盘（原编码、原行尾、原子写）。没有草稿返回 nil；写成功返回换上新文本的内容，草稿删掉。
    mutating func write(_ id: String, to url: URL, content: TabContent, fileManager: FileManager = .default) throws -> TabContent? {
        guard let draft = drafts[id], let original = content.text, let encoding = content.encodingName else { return nil }
        try TextFileSaver.write(draft, to: url, encodingName: encoding, original: original)
        let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        drafts[id] = nil
        // 内容里存磁盘上的样子（行尾照旧），下次保存才知道该用哪种行尾
        return content.replacingText(LineEnding.detect(in: original).apply(to: draft), modified: modified)
    }

    /// 磁盘上的文件比读进来时新（别人改过了）。
    static func isDiskNewer(at url: URL, than loaded: Date?, fileManager: FileManager = .default) -> Bool {
        guard let loaded else { return false }
        let onDisk = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return onDisk != loaded
    }
}
