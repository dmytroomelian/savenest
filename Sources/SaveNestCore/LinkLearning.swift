import Foundation

public enum LinkImportance: String, Codable, CaseIterable {
    case important, notNeeded
    public var title: String { self == .important ? "Important" : "Not needed" }
}

public struct ImportanceSuggestion: Equatable {
    public let importance: LinkImportance?
    public let reason: String
}

/// An explainable, local learner. Only explicit labels are training examples.
public enum LinkLearning {
    public static func suggest(_ link: SavedLink, examples: [SavedLink]) -> ImportanceSuggestion {
        if let choice = link.importance { return .init(importance: choice, reason: "You marked this link \(choice.title.lowercased()).") }
        if link.isFavorite || !link.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(importance: .important, reason: link.isFavorite ? "You favorited this link." : "You saved a note with this link.")
        }
        let tags = Set(link.tags.map(LinkSearch.folded))
        let related = examples.filter { other in
            other.id != link.id && Library.identity(other.url) != Library.identity(link.url) && other.importance != nil &&
            (other.domain.lowercased() == link.domain.lowercased() || !tags.isDisjoint(with: other.tags.map(LinkSearch.folded)))
        }
        // Require three separate examples and strong agreement; conflicting or sparse feedback asks the user.
        let unique = Dictionary(grouping: related, by: { Library.identity($0.url) }).values.compactMap(\.first)
        guard unique.count >= 3 else { return .init(importance: nil, reason: "Is this worth keeping? Label a few links to teach Savenest what matters.") }
        let positive = unique.filter { $0.importance == .important }.count
        let agreement = Double(max(positive, unique.count - positive)) / Double(unique.count)
        guard agreement >= 0.8 else { return .init(importance: nil, reason: "Your choices on similar links are mixed. You decide.") }
        return .init(importance: positive > unique.count / 2 ? .important : .notNeeded,
                     reason: "Based on \(unique.count) links you labeled with the same website or tags.")
    }
}

public enum ClipboardLink {
    /// Only a single complete web URL; never extract URLs from copied prose or credentials.
    public static func parse(_ text: String) -> URL? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 8192, !clean.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else { return nil }
        return Library.validatedURL(clean)
    }
}

public enum UsageEvent: String, Codable, CaseIterable {
    case appOpened = "app_opened", linksSaved = "links_saved", clipboardSaved = "clipboard_saved"
    case noteSaved = "note_saved", tagsSaved = "tags_saved", linkOpened = "link_opened"
    case linkCopied = "link_copied", linksArchived = "links_archived", importanceLabeled = "importance_labeled"
    public var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

public struct UsageBatch: Codable, Equatable {
    public let batchID: UUID
    public let counts: [String: Int]
    public init(counts: [UsageEvent: Int]) {
        batchID = UUID()
        self.counts = Dictionary(uniqueKeysWithValues: counts.filter { $0.value > 0 }.map { ($0.key.rawValue, min($0.value, 1000)) })
    }
}

public struct UsageAccumulator {
    public private(set) var enabled = false
    private var counts: [UsageEvent: Int] = [:]
    public init() {}
    public mutating func configure(enabled: Bool) {
        self.enabled = enabled
        if !enabled { counts = [:] }
    }
    public mutating func record(_ event: UsageEvent, count: Int = 1) {
        guard enabled, count > 0 else { return }
        counts[event] = (counts[event] ?? 0) + min(count, 1000)
        counts[event] = min(counts[event]!, 1000)
    }
    public mutating func drain() -> UsageBatch? {
        guard enabled, !counts.isEmpty else { return nil }
        defer { counts = [:] }
        return UsageBatch(counts: counts)
    }
}
