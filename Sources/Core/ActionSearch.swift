import Foundation

public enum ActionSearch {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let title: String
        public let location: String
        public let shortcut: String?
        public let keywords: String
        public let enabled: Bool

        public init(id: String, title: String, location: String, shortcut: String?, keywords: String, enabled: Bool) {
            self.id = id
            self.title = title
            self.location = location
            self.shortcut = shortcut
            self.keywords = keywords
            self.enabled = enabled
        }
    }

    public static func matching(_ query: String, in entries: [Entry]) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        let words = query.split(whereSeparator: \.isWhitespace)
        return entries.enumerated().compactMap { index, entry -> (Int, Int, Entry)? in
            let title = entry.title.lowercased()
            let shortcut = entry.shortcut?.lowercased() ?? ""
            let search = [title, entry.location.lowercased(), entry.keywords.lowercased(), shortcut].joined(separator: " ")
            guard words.allSatisfy({ search.contains($0) }) else { return nil }
            let rank = title.trimmingCharacters(in: CharacterSet(charactersIn: "…")) == query || shortcut == query ? 0
                : title.hasPrefix(query) ? 1 : title.contains(query) ? 2 : 3
            return (rank, index, entry)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }
}
