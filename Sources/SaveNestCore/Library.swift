import Foundation

public struct SavedLink: Identifiable, Codable, Equatable {
    public var id: UUID
    public var url: String
    public var title: String
    public var iconURL: String? = nil
    public var browser: String
    public var createdAt: Date
    public var collection: String
    public var note: String
    public var tags: [String]
    public var isFavorite: Bool
    public var isArchived: Bool
    public var importance: LinkImportance? = nil
    public var archiveHistory: [Date] = []

    public init(url: String, title: String, browser: String = "Manual", collection: String = "Inbox") {
        id = UUID(); self.url = url; self.title = title; self.browser = browser
        createdAt = Date(); self.collection = collection; note = ""; tags = []
        isFavorite = false; isArchived = false
    }
    private enum CodingKeys: String, CodingKey { case id, url, title, iconURL, browser, createdAt, collection, note, tags, isFavorite, isArchived, importance, archiveHistory }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); url = try c.decode(String.self, forKey: .url)
        iconURL = try c.decodeIfPresent(String.self, forKey: .iconURL)
        title = try c.decode(String.self, forKey: .title); browser = try c.decode(String.self, forKey: .browser)
        createdAt = try c.decode(Date.self, forKey: .createdAt); collection = try c.decode(String.self, forKey: .collection)
        note = try c.decode(String.self, forKey: .note)
        tags = Self.normalizedTags(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite); isArchived = try c.decode(Bool.self, forKey: .isArchived)
        importance = try c.decodeIfPresent(LinkImportance.self, forKey: .importance)
        archiveHistory = try c.decodeIfPresent([Date].self, forKey: .archiveHistory) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(url, forKey: .url); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(iconURL, forKey: .iconURL)
        try c.encode(browser, forKey: .browser); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(collection, forKey: .collection); try c.encode(note, forKey: .note)
        try c.encode(tags, forKey: .tags); try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isArchived, forKey: .isArchived); try c.encodeIfPresent(importance, forKey: .importance)
        // Keep legacy files free of an empty optional key while preserving real history.
        if !archiveHistory.isEmpty { try c.encode(archiveHistory, forKey: .archiveHistory) }
    }
    public static func normalizedTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let tag = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")).prefix(50))
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }
    public static func parseTags(_ text: String) -> [String] { normalizedTags(text.components(separatedBy: ",")) }
    public var domain: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
    public func matches(_ query: String) -> Bool {
        LinkSearch.score(query: query, title: title, url: url, note: note, tags: tags, extra: collection + " " + browser) != nil
    }
}

public struct Library: Codable, Equatable {
    public var version = 1
    public var links: [SavedLink] = []
    public var collections: [String] = ["Inbox", "Inspiration", "Read later"]
    public init() {}

    public static func validatedURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Preserve meaningful query strings and fragments; fold only URL scheme/host and root slash.
    public static func identity(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw) else { return raw }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? raw
    }

    /// Saving an annotation updates the matching link without changing its original date or archive state.
    @discardableResult public mutating func saveAnnotated(_ link: SavedLink) -> Bool {
        guard Self.validatedURL(link.url) != nil else { return false }
        if let index = links.firstIndex(where: { Self.identity($0.url) == Self.identity(link.url) }) {
            if let iconURL = link.iconURL { links[index].iconURL = iconURL }
            links[index].title = link.title
            links[index].note = link.note
            links[index].tags = SavedLink.normalizedTags(link.tags)
        } else {
            var normalized = link; normalized.tags = SavedLink.normalizedTags(link.tags)
            insert([normalized])
        }
        return true
    }
    @discardableResult public mutating func insert(_ candidates: [SavedLink]) -> Int {
        var existing = Set(links.map { Self.identity($0.url) })
        var added: [SavedLink] = []
        for var link in candidates {
            guard let url = Self.validatedURL(link.url), existing.insert(Self.identity(url.absoluteString)).inserted else { continue }
            link.url = url.absoluteString
            if link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { link.title = link.domain }
            if !collections.contains(link.collection) { collections.append(link.collection) }
            added.append(link)
        }
        links.insert(contentsOf: added, at: 0)
        return added.count
    }
}

public struct LibraryFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
        guard library.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return library
    }
    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: [.atomic])
    }
}
