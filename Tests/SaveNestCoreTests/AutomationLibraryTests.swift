import Foundation
import SaveNestCore

func runAutomationLibraryChecks() throws {
    typealias Value = AutomationValue
    func object(_ values: [String: Value]) -> Value { .object(values) }
    func items(_ result: AutomationLibraryResult) -> [[String: Value]] { result.result["items"]!.array!.map { $0.object! } }
    func invoke(_ tool: String, _ values: [Value], _ library: Library) throws -> AutomationLibraryResult {
        try AutomationLibrary.execute(tool: tool, arguments: ["items": .array(values)], library: library)
    }
    var original = SavedLink(url: "https://example.com/article?version=1#section", title: "Authentication guide", collection: "Research")
    original.note = "Remember token rotation"; original.tags = ["Security", "Backend"]
    original.createdAt = Date(timeIntervalSince1970: 1_700_000_000); original.isFavorite = true
    var library = Library(); library.links = [original]; library.collections.append("Research")

    let duplicate = try invoke("add_links", [object(["url": .string("https://EXAMPLE.com/article?version=1#section"), "note": .string("replace"), "tags": .array([.string("new")])])], library)
    XCTAssertFalse(duplicate.changed); XCTAssertEqual(duplicate.library, library)
    XCTAssertEqual(items(duplicate)[0]["code"]?.string, "already_saved")
    XCTAssertEqual(items(duplicate)[0]["record"]?.object?["note"]?.string, original.note)

    let mixed = try invoke("add_links", [
        object(["url": .string("https://example.com/new"), "title": .string("New link"), "tags": .array([.string("Swift"), .string("swift")])]),
        object(["url": .string("file:///private/secret")]),
        object(["url": .string("https://example.com/new")]),
        object(["url": .string("https://user:password@example.com/private")])
    ], library)
    XCTAssertTrue(mixed.changed); XCTAssertEqual(mixed.library.links.count, 2)
    XCTAssertEqual(mixed.result["completed"]?.int, 1); XCTAssertEqual(mixed.result["skipped"]?.int, 1); XCTAssertEqual(mixed.result["failed"]?.int, 2)
    XCTAssertEqual(mixed.library.links[0].tags, ["Swift"])
    XCTAssertEqual(library.links, [original])

    let rev = AutomationLibrary.revision(original)
    let patch: [String: Value] = ["id": .string(original.id.uuidString), "revision": .string(rev), "favorite": .bool(false), "add_tags": .array([.string("API")]), "remove_tags": .array([.string("backend")])]
    let edited = try invoke("update_links", [object(patch)], library)
    let updated = edited.library.links[0]
    XCTAssertEqual(updated.note, original.note); XCTAssertEqual(updated.title, original.title)
    XCTAssertEqual(updated.createdAt, original.createdAt); XCTAssertEqual(updated.url, original.url)
    XCTAssertEqual(updated.tags, ["Security", "API"]); XCTAssertFalse(updated.isFavorite)
    XCTAssertTrue(AutomationLibrary.revision(updated) != rev)
    let stale = try invoke("remove_links", [object(["id": .string(original.id.uuidString), "revision": .string(rev)])], edited.library)
    XCTAssertFalse(stale.changed); XCTAssertEqual(items(stale)[0]["code"]?.string, "stale_revision")
    let staleUpdate = try invoke("update_links", [object(patch)], edited.library)
    XCTAssertEqual(staleUpdate.library, edited.library)
    XCTAssertEqual(items(staleUpdate)[0]["code"]?.string, "stale_revision")

    let invalidPatch = try invoke("update_links", [object(["id": .string(original.id.uuidString), "revision": .string(rev), "note": .string("must not persist"), "archived": .string("true")])], library)
    XCTAssertEqual(invalidPatch.library, library); XCTAssertEqual(invalidPatch.result["failed"]?.int, 1)
    let invalidTags = try invoke("update_links", [object(["id": .string(original.id.uuidString), "revision": .string(rev), "tags": .array([]), "add_tags": .array([.string("bad")])])], library)
    XCTAssertFalse(invalidTags.changed)
    let clear = try invoke("update_links", [object(["id": .string(original.id.uuidString), "revision": .string(rev), "note": .string(""), "tags": .array([]), "collection": .string("Work")])], library)
    XCTAssertEqual(clear.library.links[0].note, ""); XCTAssertEqual(clear.library.links[0].tags, [])
    XCTAssertTrue(clear.library.collections.contains("Work"))
    let removal = try invoke("remove_links", [object(["id": .string(original.id.uuidString), "revision": .string(rev)])], library)
    XCTAssertTrue(removal.changed); XCTAssertTrue(removal.library.links.isEmpty)
    let repeated = try invoke("update_links", [object(patch), object(patch)], library)
    XCTAssertEqual(repeated.result["completed"]?.int, 1); XCTAssertEqual(repeated.result["failed"]?.int, 1)
    XCTAssertThrowsError(try invoke("remove_links", Array(repeating: object([:]), count: 21), library))
    XCTAssertThrowsError(try invoke("add_links", [], library))
    let unknownField = try invoke("update_links", [object(["id": .string(original.id.uuidString), "revision": .string(rev), "url": .string("https://wrong.test")])], library)
    XCTAssertFalse(unknownField.changed)

    let get = try AutomationLibrary.execute(tool: "get_links", arguments: ["ids": .array([.string(original.id.uuidString), .string(UUID().uuidString)])], library: library)
    XCTAssertEqual(get.result["completed"]?.int, 1); XCTAssertEqual(get.result["failed"]?.int, 1)
    XCTAssertEqual(items(get)[0]["record"]?.object?["revision"]?.string, rev)
    var hiddenField = original; hiddenField.iconURL = "https://example.com/icon.png"
    XCTAssertTrue(AutomationLibrary.revision(hiddenField) != rev)

    var archived = SavedLink(url: "https://archive.example.com", title: "Hidden archive")
    archived.isArchived = true
    library.links.append(archived)
    let searchable = library.links.map { AutomationLibrary.record($0) }
    let defaultSearch = try AutomationLibrary.search(records: searchable, arguments: [:])
    XCTAssertEqual(defaultSearch["total"]?.int, 1)
    let noteSearch = try AutomationLibrary.search(records: searchable, arguments: ["query": .string("token rotation")])
    XCTAssertEqual(noteSearch["items"]?.array?.first?.object?["id"]?.string, original.id.uuidString)
    let archiveSearch = try AutomationLibrary.search(records: searchable, arguments: ["filters": object(["archived": .bool(true)])])
    XCTAssertEqual(archiveSearch["items"]?.array?.first?.object?["id"]?.string, archived.id.uuidString)
    let filtered = try AutomationLibrary.search(records: searchable, arguments: ["filters": object([
        "tags": .array([.string("security"), .string("Backend")]), "domain": .string("example.com"),
        "collection": .string("Research"), "favorite": .bool(true), "browser": .string("Manual"),
        "created_after": .string("2023-11-14T00:00:00Z"), "created_before": .string("2023-11-15T00:00:00Z")
    ])])
    XCTAssertEqual(filtered["total"]?.int, 1)
    let missed = try AutomationLibrary.search(records: searchable, arguments: ["filters": object(["tags": .array([.string("Security"), .string("missing")])])])
    XCTAssertEqual(missed["total"]?.int, 0)
    XCTAssertThrowsError(try AutomationLibrary.search(records: searchable, arguments: ["filters": object(["created_after": .string("yesterday")])]))
    XCTAssertThrowsError(try AutomationLibrary.search(records: searchable, arguments: ["filters": object(["archived": .string("true")])]))
    XCTAssertThrowsError(try AutomationLibrary.search(records: searchable, arguments: ["limit": .number(101)]))
    XCTAssertThrowsError(try AutomationLibrary.search(records: searchable, arguments: ["limit": .number(0.5)]))
    XCTAssertThrowsError(try AutomationLibrary.search(records: searchable, arguments: ["filters": object(["created_after": .string("2024-01-01T00:00:00Z"), "created_before": .string("2023-01-01T00:00:00Z")])]))

    let many = (0..<105).map { i -> [String: Value] in
        var link = SavedLink(url: "https://example.com/\(i)", title: "Record \(i)")
        link.createdAt = Date(timeIntervalSince1970: Double(i))
        return AutomationLibrary.record(link)
    }
    let first = try AutomationLibrary.search(records: many, arguments: [:])
    XCTAssertEqual(first["items"]?.array?.count, 50); XCTAssertEqual(first["total"]?.int, 105)
    let second = try AutomationLibrary.search(records: many, arguments: ["cursor": first["next_cursor"]!])
    XCTAssertEqual(second["items"]?.array?.count, 50)
    let last = try AutomationLibrary.search(records: many, arguments: ["cursor": second["next_cursor"]!])
    XCTAssertEqual(last["items"]?.array?.count, 5); XCTAssertEqual(last["next_cursor"], .null)
    let firstIDs = Set(first["items"]!.array!.map { $0.object!["id"]!.string! })
    let secondIDs = Set(second["items"]!.array!.map { $0.object!["id"]!.string! })
    XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))
    XCTAssertThrowsError(try AutomationLibrary.search(records: Array(many.dropFirst()), arguments: ["cursor": first["next_cursor"]!]))
    XCTAssertThrowsError(try AutomationLibrary.search(records: many, arguments: ["cursor": first["next_cursor"]!, "query": .string("Record")]))

    // Distinct live tabs with the same URL must retain distinct action references.
    let tabs: [[String: Value]] = [
        ["source": .string("open"), "id": .string("tab1"), "tab_ref": .string("one"), "url": .string(original.url), "title": .string("First tab"), "context": .string("body-only secret")],
        ["source": .string("open"), "id": .string("tab2"), "tab_ref": .string("two"), "url": .string(original.url), "title": .string("Second tab")]
    ]
    let tabSearch = try AutomationLibrary.search(records: tabs, arguments: [:])
    XCTAssertEqual(tabSearch["total"]?.int, 2)
    XCTAssertNil(tabSearch["items"]?.array?.first?.object?["context"])
    let noBody = try AutomationLibrary.search(records: tabs, arguments: ["query": .string("body-only")])
    XCTAssertEqual(noBody["total"]?.int, 0)
    let allValues: Value = object(["null": .null, "bool": .bool(true), "number": .number(3), "string": .string("é 🌱"), "array": .array([.string("a")])])
    try XCTAssertEqual(try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(allValues)), allValues)
    XCTAssertNil(Value.number(Double.infinity).int)
    print("Passed MCP library operation checks")
}
