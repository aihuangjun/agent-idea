import Foundation

public struct SourceSymbol: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case type, interface, function, variable
        public var isType: Bool { self == .type || self == .interface }
    }

    public let name: String
    public let qualifiedName: String
    public let kind: Kind
    public let line: Int
    public let ch: Int
}

public struct SourceOutline: Codable, Sendable {
    public let path: String
    public let symbols: [SourceSymbol]
    public let java: JavaSource?
}

public enum ProjectSearch {
    public enum Scope: String, CaseIterable, Sendable { case all, types, files, symbols }

    public struct IndexedSymbol: Sendable {
        public let symbol: SourceSymbol
        public let path: String
        fileprivate let key: FileSearchEntry

        public init(symbol: SourceSymbol, path: String) {
            self.symbol = symbol
            self.path = path
            self.key = FileSearchEntry(path: symbol.qualifiedName, name: symbol.name)
        }
    }

    public struct Result: Identifiable, Equatable, Sendable {
        public let path: String
        public let symbol: SourceSymbol?
        public let location: SourceLocation?
        public let matchedNameIndices: [Int]

        public var name: String { symbol?.name ?? (path as NSString).lastPathComponent }
        /// 显示项目相对路径。根目录的文件加上 ./，让它与同名文件的其它位置区分开。
        public var displayPath: String { path.contains("/") ? path : "./" + path }
        public var id: ID { ID(path: path, symbol: symbol) }

        public struct ID: Hashable {
            let path: String
            let symbol: SourceSymbol?
        }

        public init(path: String, symbol: SourceSymbol? = nil, location: SourceLocation? = nil, matchedNameIndices: [Int] = []) {
            self.path = path
            self.symbol = symbol
            self.location = location
            self.matchedNameIndices = matchedNameIndices
        }
    }

    public static func search(
        _ rawQuery: String, scope: Scope, files: [FileSearchEntry], symbols: [IndexedSymbol], root: String,
        limit: Int = 100, shouldStop: () -> Bool = { false }
    ) -> [Result] {
        let reference = FileReference.parseQuery(rawQuery, projectRoot: root, preservingRoot: true)
        let name = reference.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var matches: [(score: Int, result: Result)] = []
        if scope == .all || scope == .files {
            matches = FileSearch.search(name, in: files, limit: limit, shouldStop: shouldStop).map {
                ($0.score, Result(path: $0.entry.path, location: reference.location, matchedNameIndices: $0.matchedNameIndices))
            }
        }
        // 「全部」里，完整文件名优先作为文件查找。有相同拼写的限定符号时可在「类」或「函数和变量」页查找。
        let isFilenameQuery = scope == .all && isCompleteFilename(name, hasFileMatch: !matches.isEmpty)
        if scope != .files, !isFilenameQuery, reference.location == nil, !name.contains("/") {
            let query = Array(name.lowercased())
            let initials = name.count > 1 && name.allSatisfy(\.isUppercase) ? query : []
            for (offset, entry) in symbols.enumerated() {
                if offset % 256 == 0, shouldStop() { return [] }
                let symbol = entry.symbol
                if scope == .types && !symbol.kind.isType { continue }
                if scope == .symbols && symbol.kind.isType { continue }
                guard let match = FileSearch.scoreSymbol(entry.key, query: query) else { continue }
                let qualified = entry.key.lowercasedPath == query
                let hump = !initials.isEmpty && Array(symbol.name.filter(\.isUppercase).lowercased()) == initials
                let score = qualified ? 1000 : hump ? max(match.score, 820) : match.score
                let position = SourceLocation(line: symbol.line + 1, column: symbol.ch + 1)
                matches.append((score, Result(path: entry.path, symbol: symbol, location: position, matchedNameIndices: match.matchedNameIndices)))
            }
        }
        if shouldStop() { return [] }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let nameOrder = $0.result.name.localizedStandardCompare($1.result.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if $0.result.path != $1.result.path { return $0.result.path < $1.result.path }
            return ($0.result.location?.line ?? 0, $0.result.location?.column ?? 0) < ($1.result.location?.line ?? 0, $1.result.location?.column ?? 0)
        }.prefix(limit).map(\.result)
    }

    private static func isCompleteFilename(_ name: String, hasFileMatch: Bool) -> Bool {
        guard FileSearch.Query(name)?.exactName != nil else { return false }
        let suffix = (name as NSString).pathExtension.lowercased()
        return hasFileMatch || name.hasPrefix(".") || Language.recognizesExtension(suffix) || FileCategory.imageExtensions.contains(suffix) || suffix == "pdf"
    }
}
