import Foundation
import CryptoKit

public struct AutomationLibraryResult {
    public let library: Library
    public let result: [String: AutomationValue]
    public let changed: Bool
}

/// Pure operations. The native application must authorize, persist, and only then report success.
public enum AutomationLibrary {
    public static let maximumMutationItems = 20
    public static let maximumReadItems = 100

    public static func execute(tool: String, arguments: [String: AutomationValue], library: Library) throws -> AutomationLibraryResult {
        if tool == "search_links" {
            return .init(library: library, result: try search(records: library.links.map { record($0) }, arguments: arguments), changed: false)
        }
        if tool == "get_links" {
            let ids = try strings(arguments["ids"], name: "ids", maximum: maximumReadItems)
            guard !ids.isEmpty else { throw invalid("Select at least one link.") }
            let results: [AutomationValue] = ids.enumerated().map { offset, raw in
                guard let id = UUID(uuidString: raw), let link = library.links.first(where: { $0.id == id }) else {
                    return item(offset, id: raw, status: "failed", code: "not_found", message: "Saved link not found.")
                }
                return item(offset, id: raw, status: "completed", record: record(link))
            }
            return .init(library: library, result: batch(results), changed: false)
        }
        guard ["add_links", "update_links", "remove_links"].contains(tool) else {
            throw AutomationFailure("unknown_tool", "This library operation is not supported.")
        }
        guard let values = arguments["items"]?.array, !values.isEmpty, values.count <= maximumMutationItems else {
            throw invalid("Provide between 1 and \(maximumMutationItems) items.")
        }
        var next = library
        var results: [AutomationValue] = []
        var handled = Set<UUID>()
        for (offset, value) in values.enumerated() {
            var selectedID: String?
            do {
                guard let fields = value.object else { throw invalid("Each item must be an object.") }
                if tool == "add_links" {
                    let allowed: Set<String> = ["url", "title", "note", "tags", "collection"]
                    try requireKeys(fields, allowed: allowed)
                    let raw = try requiredString(fields["url"], name: "url", maximum: 16_384)
                    guard let url = Library.validatedURL(raw), !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        throw invalid("Use an http or https URL without credentials or control characters.")
                    }
                    let title = try optionalString(fields, key: "title", maximum: 4_096) ?? ""
                    let note = try optionalString(fields, key: "note", maximum: 65_536) ?? ""
                    let collection = try collection(fields) ?? "Inbox"
                    let tags = try optionalTags(fields, key: "tags") ?? []
                    if let existing = next.links.first(where: { Library.identity($0.url) == Library.identity(url.absoluteString) }) {
                        results.append(item(offset, id: existing.id.uuidString, status: "skipped", code: "already_saved", message: "Already saved; existing details were preserved.", record: record(existing)))
                        continue
                    }
                    var link = SavedLink(url: url.absoluteString, title: title, browser: "MCP", collection: collection)
                    link.note = note; link.tags = tags
                    _ = next.insert([link])
                    let saved = next.links.first(where: { $0.id == link.id })!
                    results.append(item(offset, id: saved.id.uuidString, status: "completed", record: record(saved)))
                } else {
                    let allowed: Set<String> = tool == "remove_links" ? ["id", "revision"] : ["id", "revision", "title", "note", "tags", "add_tags", "remove_tags", "collection", "favorite", "archived"]
                    try requireKeys(fields, allowed: allowed)
                    let rawID = try requiredString(fields["id"], name: "id", maximum: 100)
                    selectedID = rawID
                    guard let id = UUID(uuidString: rawID), let index = next.links.firstIndex(where: { $0.id == id }) else {
                        throw AutomationFailure("not_found", "Saved link not found.")
                    }
                    guard handled.insert(id).inserted else { throw invalid("Select a saved link only once per batch.") }
                    let expected = try requiredString(fields["revision"], name: "revision", maximum: 200)
                    guard expected == revision(next.links[index]) else {
                        throw AutomationFailure("stale_revision", "This link changed. Read its current revision before trying again.")
                    }
                    if tool == "remove_links" {
                        next.links.remove(at: index)
                        results.append(item(offset, id: rawID, status: "completed"))
                    } else {
                        var link = next.links[index]
                        if let title = try optionalString(fields, key: "title", maximum: 4_096) {
                            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Title must not be empty.") }
                            link.title = title
                        }
                        if let note = try optionalString(fields, key: "note", maximum: 65_536) { link.note = note }
                        if let name = try collection(fields) { link.collection = name }
                        if let tags = try optionalTags(fields, key: "tags") {
                            guard fields["add_tags"] == nil, fields["remove_tags"] == nil else {
                                throw invalid("Use tags replacement or add_tags/remove_tags, not both.")
                            }
                            link.tags = tags
                        }
                        if let tags = try optionalTags(fields, key: "remove_tags") {
                            let removed = Set(tags.map { $0.lowercased() })
                            link.tags.removeAll { removed.contains($0.lowercased()) }
                        }
                        if let tags = try optionalTags(fields, key: "add_tags") { link.tags = SavedLink.normalizedTags(link.tags + tags) }
                        if let value = try optionalBool(fields, key: "favorite") { link.isFavorite = value }
                        if let value = try optionalBool(fields, key: "archived") { link.isArchived = value }
                        let changed = link != next.links[index]
                        next.links[index] = link
                        if !next.collections.contains(link.collection) { next.collections.append(link.collection) }
                        results.append(item(offset, id: rawID, status: changed ? "completed" : "skipped", code: changed ? nil : "unchanged", record: record(link)))
                    }
                }
            } catch let error as AutomationFailure {
                results.append(item(offset, id: selectedID, status: "failed", code: error.code, message: error.message))
            }
        }
        return .init(library: next, result: batch(results), changed: next != library)
    }

    public static func record(_ link: SavedLink, includeNote: Bool = true) -> [String: AutomationValue] {
        var value: [String: AutomationValue] = [
            "id": .string(link.id.uuidString), "source": .string("saved"), "revision": .string(revision(link)),
            "url": .string(link.url), "title": .string(link.title), "tags": .array(link.tags.map(AutomationValue.string)),
            "collection": .string(link.collection), "browser": .string(link.browser), "created_at": .string(dateString(link.createdAt)),
            "favorite": .bool(link.isFavorite), "archived": .bool(link.isArchived)
        ]
        if includeNote { value["note"] = .string(link.note) }
        return value
    }

    /// Every saved field contributes, including fields outside the editable MCP surface.
    public static func revision(_ link: SavedLink) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest((try? encoder.encode(link)) ?? Data())
    }

    /// Search only the permitted records supplied by the native owner. Never reads page content.
    public static func search(records: [[String: AutomationValue]], arguments: [String: AutomationValue]) throws -> [String: AutomationValue] {
        let query = try optionalString(arguments, key: "query", maximum: 2_000) ?? ""
        let filters: [String: AutomationValue]
        if let raw = arguments["filters"] {
            guard let object = raw.object else { throw invalid("filters must be an object.") }
            filters = object
        } else { filters = [:] }
        try requireKeys(filters, allowed: ["tags", "collection", "created_after", "created_before", "domain", "browser", "favorite", "archived"])
        let tags = try optionalTags(filters, key: "tags")
        let collection = try optionalString(filters, key: "collection", maximum: 200)
        let browser = try optionalString(filters, key: "browser", maximum: 200)
        let domain = try optionalString(filters, key: "domain", maximum: 253)
        if let domain, domain.isEmpty || domain.contains("/") || domain.contains(":") { throw invalid("domain must be a hostname such as example.com.") }
        let favorite = try optionalBool(filters, key: "favorite")
        let archived = try optionalBool(filters, key: "archived")
        let after = try filterDate(filters, key: "created_after")
        let before = try filterDate(filters, key: "created_before")
        if let after, let before, after > before { throw invalid("created_after must not be later than created_before.") }
        let limit: Int
        if let raw = arguments["limit"] {
            guard let n = raw.int, (1...maximumReadItems).contains(n) else { throw invalid("limit must be an integer from 1 to 100.") }
            limit = n
        } else { limit = 50 }
        let fractionalDates = ISO8601DateFormatter(); fractionalDates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeDates = ISO8601DateFormatter()
        func recordDate(_ record: [String: AutomationValue]) -> Date? {
            guard let raw = record["created_at"]?.string ?? record["last_visited"]?.string else { return nil }
            return fractionalDates.date(from: raw) ?? wholeDates.date(from: raw)
        }
        var ranked: [(record: [String: AutomationValue], score: Int, date: Date)] = []
        let visibleFields: Set<String> = ["id", "source", "saved_id", "revision", "url", "title", "note", "tags", "collection", "browser", "profile", "created_at", "last_visited", "favorite", "archived", "tab_ref", "history_ref"]
        for candidate in records {
            // Browser extraction caches can contain article text. Even accidental callers
            // must not return that content through this metadata-only interface.
            let record = candidate.filter { visibleFields.contains($0.key) }
            let source = record["source"]?.string ?? "saved"
            if source == "saved", (record["archived"]?.bool ?? false) != (archived ?? false) { continue }
            if source != "saved", archived == true { continue }
            if let favorite, record["favorite"]?.bool != favorite { continue }
            if let collection, LinkSearch.folded(record["collection"]?.string ?? "") != LinkSearch.folded(collection) { continue }
            if let browser, LinkSearch.folded(record["browser"]?.string ?? "") != LinkSearch.folded(browser) { continue }
            let recordTags = record["tags"]?.array?.compactMap(\.string) ?? []
            if let tags, !Set(tags.map(LinkSearch.folded)).isSubset(of: Set(recordTags.map(LinkSearch.folded))) { continue }
            if let domain {
                let host = URL(string: record["url"]?.string ?? "")?.host?.lowercased() ?? ""
                let wanted = domain.lowercased()
                if host != wanted && host != "www." + wanted { continue }
            }
            let date = recordDate(record)
            if after != nil || before != nil {
                guard let date else { continue }
                if let after, date < after { continue }
                if let before, date > before { continue }
            }
            guard let score = LinkSearch.score(query: query, title: record["title"]?.string ?? "", url: record["url"]?.string ?? "",
                                              note: record["note"]?.string ?? "", tags: recordTags,
                                              extra: (record["collection"]?.string ?? "") + " " + (record["browser"]?.string ?? "")) else { continue }
            ranked.append((record, score, date ?? .distantPast))
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            let first = ($0.record["source"]?.string ?? "") + ":" + ($0.record["id"]?.string ?? "")
            let second = ($1.record["source"]?.string ?? "") + ":" + ($1.record["id"]?.string ?? "")
            return first < second
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = digest(try encoder.encode(AutomationValue.object([
            "query": .string(query), "filters": .object(filters), "records": .array(ranked.map { .object($0.record) })
        ])))
        var offset = 0
        if let raw = arguments["cursor"] {
            guard let string = raw.string, string.utf8.count <= 1_024, let data = Data(base64Encoded: string),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: data), cursor.fingerprint == fingerprint,
                  cursor.offset >= 0, cursor.offset <= ranked.count else {
                throw AutomationFailure("stale_cursor", "Search changed or cursor is invalid. Start a new search.")
            }
            offset = cursor.offset
        }
        let page = Array(ranked.dropFirst(offset).prefix(limit))
        let nextOffset = offset + page.count
        let cursor: AutomationValue = nextOffset < ranked.count
            ? .string(try encoder.encode(Cursor(offset: nextOffset, fingerprint: fingerprint)).base64EncodedString()) : .null
        return ["items": .array(page.map { .object($0.record) }), "total": .number(Double(ranked.count)), "next_cursor": cursor]
    }

    private struct Cursor: Codable { let offset: Int; let fingerprint: String }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    private static func filterDate(_ fields: [String: AutomationValue], key: String) throws -> Date? {
        guard let raw = fields[key] else { return nil }
        guard let value = raw.string, value.utf8.count <= 100, let date = parseDate(value) else { throw invalid("\(key) must be an ISO 8601 date and time.") }
        return date
    }
    private static func requiredString(_ value: AutomationValue?, name: String, maximum: Int) throws -> String {
        guard let string = value?.string, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: { $0.value == 0 }) else { throw invalid("\(name) must be a string of at most \(maximum) UTF-8 bytes without NUL characters.") }
        return string
    }
    private static func optionalString(_ fields: [String: AutomationValue], key: String, maximum: Int) throws -> String? {
        guard fields[key] != nil else { return nil }
        return try requiredString(fields[key], name: key, maximum: maximum)
    }
    private static func strings(_ value: AutomationValue?, name: String, maximum: Int) throws -> [String] {
        guard let values = value?.array, values.count <= maximum else { throw invalid("\(name) must be an array with at most \(maximum) entries.") }
        return try values.map { try requiredString($0, name: name, maximum: 500) }
    }
    private static func optionalTags(_ fields: [String: AutomationValue], key: String) throws -> [String]? {
        guard let value = fields[key] else { return nil }
        return SavedLink.normalizedTags(try strings(value, name: key, maximum: 100))
    }
    private static func optionalBool(_ fields: [String: AutomationValue], key: String) throws -> Bool? {
        guard let raw = fields[key] else { return nil }
        guard let value = raw.bool else { throw invalid("\(key) must be true or false.") }
        return value
    }
    private static func collection(_ fields: [String: AutomationValue]) throws -> String? {
        guard let raw = try optionalString(fields, key: "collection", maximum: 200) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !["All links", "Favorites", "Archive"].contains(name) else { throw invalid("Choose a nonempty collection name other than a reserved view.") }
        return name
    }
    private static func requireKeys(_ fields: [String: AutomationValue], allowed: Set<String>) throws {
        guard Set(fields.keys).isSubset(of: allowed) else { throw invalid("Unknown or unsupported fields.") }
    }
    private static func invalid(_ message: String) -> AutomationFailure { .init("invalid_arguments", message) }
    private static func item(_ index: Int, id: String? = nil, status: String, code: String? = nil, message: String? = nil, record: [String: AutomationValue]? = nil) -> AutomationValue {
        var value: [String: AutomationValue] = ["index": .number(Double(index)), "status": .string(status)]
        if let id { value["id"] = .string(id) }; if let code { value["code"] = .string(code) }
        if let message { value["message"] = .string(message) }; if let record { value["record"] = .object(record) }
        return .object(value)
    }
    private static func batch(_ items: [AutomationValue]) -> [String: AutomationValue] {
        var result: [String: AutomationValue] = ["items": .array(items)]
        for status in ["completed", "skipped", "failed"] {
            result[status] = .number(Double(items.filter { $0.object?["status"]?.string == status }.count))
        }
        return result
    }
}
