import Foundation
import SaveNestCore

final class LibraryTests {
    func testTabCleanupPlanningIsConservativeAndDomainScoped() {
        func tab(_ browser: String = "Safari", _ window: String = "1", _ index: Int, _ url: String, active: Bool = false, empty: Bool = false) -> BrowserTabSnapshot {
            BrowserTabSnapshot(browserID: browser, browserName: browser, windowID: window, windowIndex: Int(window) ?? 1, tabID: browser == "Safari" ? "" : "\(index)", index: index, title: url, url: url, isActive: active, isEmpty: empty)
        }
        let tabs = [
            tab("Safari", "1", 1, "https://example.com/page"),
            tab("Safari", "1", 2, "https://example.com/page", active: true),
            tab("Safari", "1", 3, "https://example.com/page?view=other"),
            tab("Chrome", "1", 1, "https://example.com/page"),
            tab("Safari", "1", 4, "about:blank", empty: true),
            tab("Safari", "1", 5, "https://news.example.com/story")
        ]
        let cleanup = TabCleanupPlanner.duplicateAndEmptyCandidates(tabs)
        XCTAssertEqual(Set(cleanup.map(\.id)), Set([tabs[0].id, tabs[4].id]))
        XCTAssertEqual(TabCleanupPlanner.domainCandidates(tabs, domains: ["example.com"]).count, 5)
        XCTAssertEqual(TabCleanupPlanner.domainCandidates(tabs, domains: ["news.example.com"]).map(\.id), [tabs[5].id])
        XCTAssertEqual(TabCleanupPlanner.normalizedDomain(" HTTPS://WWW.Example.com/path "), "example.com")
        XCTAssertNil(TabCleanupPlanner.normalizedDomain("not a domain"))
    }

    func testBrowserTabPayloadsDecodeAndSaveTogether() throws {
        // Safari numeric IDs are normalized by the reader; Chrome natively returns text IDs.
        let payload = Data(#"[{"browserID":"com.apple.Safari","browserName":"Safari","windowID":"42","tabID":"","index":1,"title":"Safari page","url":"https://example.com/safari"},{"browserID":"com.google.Chrome","browserName":"Chrome","windowID":"42","tabID":"1084952245","index":1,"title":"Chrome page","url":"https://example.com/chrome"}]"#.utf8)
        let tabs = try JSONDecoder().decode([OpenBrowserTab].self, from: payload)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(Set(tabs.map(\.id)).count, 2)
        XCTAssertEqual(tabs[1].tabID, "1084952245")
        var library = Library()
        let links = tabs.map { SavedLink(url: $0.url, title: $0.title, browser: $0.browserName) }
        XCTAssertEqual(library.insert(links), 2)
        XCTAssertEqual(library.insert(links), 0)
        XCTAssertEqual(Set(library.links.map(\.browser)), Set(["Safari", "Chrome"]))
        let targetJSON = Data(#"{"windowID":"42","tabID":"1084952245","index":-1,"url":"https://example.com/chrome","safari":false,"browserID":"com.google.Chrome","processID":123}"#.utf8)
        let target = try JSONDecoder().decode(CapturedTabTarget.self, from: targetJSON)
        XCTAssertEqual(target.tabID, tabs[1].tabID)
        try XCTAssertEqual(try JSONDecoder().decode(CapturedTabTarget.self, from: JSONEncoder().encode(target)).windowID, "42")
    }

    func testClipboardRequiresSingleSafeURL() {
        XCTAssertNotNil(ClipboardLink.parse("  https://example.com/path?q=one#two\n"))
        for text in ["Read https://example.com", "https://one.test\nhttps://two.test", "file:///tmp/private", "javascript:alert(1)", "https://user:pass@example.com", "", "https://example.com/a b", String(repeating: "x", count: 9000)] {
            XCTAssertNil(ClipboardLink.parse(text), text)
        }
    }
    func testImportanceLearningRequiresEvidenceAndHonorsCorrections() {
        let candidate = SavedLink(url: "https://example.com/candidate", title: "Candidate")
        var examples = (0..<3).map { value -> SavedLink in
            var link = SavedLink(url: "https://example.com/\(value)", title: "Example")
            link.importance = .notNeeded; return link
        }
        XCTAssertNil(LinkLearning.suggest(candidate, examples: Array(examples.prefix(2))).importance)
        XCTAssertEqual(LinkLearning.suggest(candidate, examples: examples).importance, .notNeeded)
        examples[0].importance = .important
        XCTAssertNil(LinkLearning.suggest(candidate, examples: examples).importance)
        var annotated = candidate; annotated.note = "Kill a stuck development port"
        XCTAssertEqual(LinkLearning.suggest(annotated, examples: examples).importance, .important)
        annotated.importance = .notNeeded
        XCTAssertEqual(LinkLearning.suggest(annotated, examples: examples).importance, .notNeeded)
        examples = examples.map { var link = $0; link.importance = .important; link.tags = ["Tools"]; return link }
        var elsewhere = SavedLink(url: "https://other.test/tool", title: "Tool"); elsewhere.tags = ["tools"]
        XCTAssertEqual(LinkLearning.suggest(elsewhere, examples: examples).importance, .important)
        elsewhere.tags = []
        XCTAssertNil(LinkLearning.suggest(elsewhere, examples: examples).importance)
        XCTAssertNil(LinkLearning.suggest(candidate, examples: Array(repeating: examples[0], count: 3)).importance)
    }
    func testAutoTaggingMatchesExistingTagsConservatively() {
        func example(_ index: Int, _ tag: String) -> SavedLink {
            var link = SavedLink(url: "https://history\(index).test/item", title: "History \(index)")
            link.tags = [tag]; return link
        }
        let examples = [
            example(1, "Swift"), example(2, "Product Design"), example(3, "AI"),
            example(4, "Research"), example(5, "Article"), example(6, "Design")
        ]
        let candidate = SavedLink(url: "https://new.test/item", title: "SWÍFT product designs with AI, reserach, and desogn")
        let suggestions = LinkAutoTagging.suggestions(for: candidate, examples: examples, limit: 10)
        XCTAssertTrue(suggestions.contains("Swift"))
        XCTAssertTrue(suggestions.contains("Product Design"))
        XCTAssertTrue(suggestions.contains("AI"))
        XCTAssertTrue(suggestions.contains("Research"))
        XCTAssertTrue(suggestions.contains("Design"))

        let substring = SavedLink(url: "https://new.test/article", title: "An article about typography")
        XCTAssertFalse(LinkAutoTagging.suggestions(for: substring, examples: [example(7, "Art")], limit: 10).contains("Art"))
        let suffix = SavedLink(url: "https://new.test/designing", title: "Designing calmer software")
        XCTAssertEqual(LinkAutoTagging.suggestions(for: suffix, examples: [example(8, "Design")]), ["Design"])
    }
    func testAutoTaggingLearnsTitleMappingsWithAgreement() {
        func example(_ url: String, _ title: String, _ tags: [String]) -> SavedLink {
            var link = SavedLink(url: url, title: title); link.tags = tags; return link
        }
        let examples = [
            example("https://one.test/async", "Async task groups", ["Swift"]),
            example("https://two.test/async", "Async streams explained", ["Swift"]),
            example("https://three.test/async", "Async office planning", ["Work"]),
            example("https://one.test/actor", "Actor isolation", ["Concurrency"]),
            example("https://one.test/release", "Release checklist one", ["Shipping"]),
            example("https://two.test/release", "Release checklist two", ["Shipping"]),
            example("https://three.test/release", "Release checklist three", ["Work"]),
            example("https://four.test/release", "Release checklist four", ["Product"]),
            example("https://five.test/release", "Release checklist five", ["Operations"])
        ]
        XCTAssertTrue(LinkAutoTagging.suggestions(
            for: SavedLink(url: "https://new.test/async", title: "Asnyc patterns"), examples: examples
        ).contains("Swift"))
        XCTAssertFalse(LinkAutoTagging.suggestions(
            for: SavedLink(url: "https://new.test/actor", title: "Actors in practice"), examples: examples
        ).contains("Concurrency"))
        XCTAssertFalse(LinkAutoTagging.suggestions(
            for: SavedLink(url: "https://new.test/release", title: "Release process"), examples: examples
        ).contains("Shipping"))
    }
    func testAutoTaggingUsesDomainHistoryAndStableRanking() {
        func example(_ url: String, _ title: String, _ tags: [String], archived: Bool = false) -> SavedLink {
            var link = SavedLink(url: url, title: title); link.tags = tags; link.isArchived = archived; return link
        }
        let examples = [
            example("https://www.example.com/one", "Focus planning", ["Productivity", "Apple"]),
            example("https://example.com/two", "Focus routines", ["productivity", "Apple"], archived: true),
            example("https://example.com/three", "Weekly review", ["Productivity", "Rare"]),
            example("https://other.test/swift", "Language notes", ["Swift"])
        ]
        let candidate = SavedLink(url: "https://example.com/new", title: "Swift focus method")
        let suggestions = LinkAutoTagging.suggestions(for: candidate, examples: examples)
        XCTAssertEqual(suggestions, ["Productivity", "Apple", "Swift"])
        XCTAssertFalse(suggestions.contains("Rare")); XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(LinkAutoTagging.applyingSuggestions(to: candidate, examples: examples).tags, suggestions)

        var alreadyTagged = candidate
        alreadyTagged.tags = ["Personal"]
        XCTAssertEqual(
            LinkAutoTagging.applyingSuggestions(to: alreadyTagged, examples: examples).tags,
            ["Personal", "Productivity", "Apple", "Swift"]
        )

        let generic = SavedLink(url: "https://example.com/generic", title: "")
        XCTAssertEqual(LinkAutoTagging.suggestions(for: generic, examples: examples), ["Productivity", "Apple"])

        let subdomain = SavedLink(url: "https://docs.example.com/new", title: "")
        XCTAssertEqual(LinkAutoTagging.suggestions(for: subdomain, examples: examples), [])

        let duplicate = example("https://example.com/new", "Old copy", ["Productivity"])
        XCTAssertEqual(LinkAutoTagging.suggestions(
            for: SavedLink(url: "https://example.com/new", title: ""), examples: Array(examples.prefix(2)) + [duplicate]
        ), [])

        let tied = (1...3).map { example("https://tie.test/\($0)", "", ["Beta", "Alpha"]) }
        XCTAssertEqual(LinkAutoTagging.suggestions(
            for: SavedLink(url: "https://tie.test/new", title: ""), examples: tied
        ), ["Alpha", "Beta"])
    }
    func testTagCompletionSelectsFirstFilteredSuggestion() {
        func exampleTag(url: String, title: String, tags: [String]) -> SavedLink {
            var link = SavedLink(url: url, title: title); link.tags = tags; return link
        }
        let suggestions = ["Research", "Design", "Product Design", "Reading"]
        XCTAssertEqual(TagCompletion.matches(input: "des", selected: [], suggestions: suggestions), ["design", "product design"])
        XCTAssertEqual(TagCompletion.firstMatch(input: "DES", selected: ["design"], suggestions: suggestions), "Product Design")
        XCTAssertEqual(TagCompletion.firstMatch(input: "add", selected: [], suggestions: ["Addiction"]), "addiction")
        XCTAssertEqual(TagCompletion.firstMatch(input: "Add", selected: [], suggestions: ["addiction"]), "Addiction")
        XCTAssertNil(TagCompletion.firstMatch(input: "", selected: [], suggestions: suggestions))
        XCTAssertNil(TagCompletion.firstMatch(input: "missing", selected: [], suggestions: suggestions))

        XCTAssertEqual(TagCaseStyle.inferred(from: ["health", "recovery", "Work"]), .lowercase)
        XCTAssertEqual(TagCaseStyle.inferred(from: ["Health", "Recovery", "work"]), .leadingUppercase)

        let history = [
            exampleTag(url: "https://one.test", title: "Addiction overview", tags: ["Addiction"]),
            exampleTag(url: "https://two.test", title: "Other", tags: ["health"]),
            exampleTag(url: "https://three.test", title: "Another", tags: ["recovery"])
        ]
        XCTAssertEqual(LinkAutoTagging.suggestions(
            for: SavedLink(url: "https://new.test", title: "Addiction support"), examples: history
        ), ["addiction"])
    }
    func testImportanceMigrationAndBackup() throws {
        var link = SavedLink(url: "https://example.com", title: "Reference")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as! [String: Any]
        object.removeValue(forKey: "importance")
        let legacy = try JSONDecoder().decode(SavedLink.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.importance)
        link.importance = .important
        try XCTAssertEqual(try JSONDecoder().decode(SavedLink.self, from: JSONEncoder().encode(link)), link)
        var library = Library(); library.links = [link]
        var annotation = link; annotation.importance = nil; annotation.note = "New note"
        library.saveAnnotated(annotation)
        XCTAssertEqual(library.links[0].importance, .important)
    }
    func testAnalyticsOptOutAndPayloadBoundary() throws {
        var accumulator = UsageAccumulator()
        accumulator.record(.linkOpened)
        XCTAssertNil(accumulator.drain())
        accumulator.configure(enabled: true)
        accumulator.record(.linksSaved, count: 3)
        accumulator.configure(enabled: false)
        accumulator.configure(enabled: true)
        XCTAssertNil(accumulator.drain()) // Opt-out discarded unsent events.
        accumulator.record(.linksSaved, count: Int.max)
        accumulator.record(.linkCopied, count: -1)
        let batch = accumulator.drain()!
        XCTAssertEqual(batch.counts, ["links_saved": 1000])
        XCTAssertNil(accumulator.drain()) // Never report one event twice.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), Set(["batchID", "counts"]))
        XCTAssertFalse(UsageBatch(counts: [.appOpened: 1]).batchID == batch.batchID)
    }
    func testLegacyReadStateIsIgnored() throws {
        let link = SavedLink(url: "https://example.com/read", title: "Read")
        let data = try JSONEncoder().encode(link)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["isRead"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SavedLink.self, from: legacyData)
        XCTAssertEqual(decoded.url, link.url)
        XCTAssertFalse(String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!.contains("isRead"))
    }

    func testArchiveUndoPreservesEditsAndExistingArchive() {
        var library = Library()
        var old = SavedLink(url: "https://example.com/old", title: "Old"); old.isArchived = true
        let fresh = SavedLink(url: "https://example.com/new", title: "New")
        library.links = [old, fresh]
        let changed = library.setArchived(true, ids: Set(library.links.map(\.id)))
        XCTAssertEqual(changed, [fresh.id])
        library.links[1].note = "Edited after archiving"; library.links[1].tags = ["Keep"]
        library.setArchived(false, ids: changed)
        XCTAssertTrue(library.links[0].isArchived); XCTAssertFalse(library.links[1].isArchived)
        XCTAssertEqual(library.links[1].note, "Edited after archiving"); XCTAssertEqual(library.links[1].tags, ["Keep"])
    }
    func testTagManagementRenamesAndDeletesAcrossLinks() {
        var library = Library()
        var first = SavedLink(url: "https://example.com/one", title: "One"); first.tags = ["Design", "Mac"]
        var second = SavedLink(url: "https://example.com/two", title: "Two"); second.tags = ["design"]
        library.links = [first, second]
        XCTAssertEqual(library.renameTag("design", to: "Product design"), 2)
        XCTAssertEqual(library.links[0].tags, ["Product design", "Mac"])
        XCTAssertEqual(library.links[1].tags, ["Product design"])
        XCTAssertEqual(library.deleteTag("mac"), 1)
        XCTAssertEqual(library.links[0].tags, ["Product design"])
    }
    func testEmptyArchiveDeletesOnlyConfirmedStillArchivedLinks() {
        var library = Library()
        library.links = (0..<4).map { SavedLink(url: "https://example.com/\($0)", title: "\($0)") }
        library.setArchived(true, ids: Set(library.links.prefix(2).map(\.id)))
        let confirmed = Set(library.links.filter(\.isArchived).map(\.id))
        library.links[1].isArchived = false // Restored while confirmation was open.
        library.links[2].isArchived = true // Archived after the snapshot.
        XCTAssertEqual(library.deleteArchived(ids: confirmed), 1)
        XCTAssertEqual(library.links.map(\.title), ["1", "2", "3"])
        XCTAssertEqual(library.deleteArchived(ids: confirmed), 0)
    }
    func testEmailShareOnlyIncludesExplicitlyChosenNote() {
        var link = SavedLink(url: "https://example.com/article?q=one&x=two#section", title: "A title\nAnother line")
        link.note = "Private saved note"
        XCTAssertEqual(EmailShare.subject(link.title), "A title Another line")
        XCTAssertEqual(EmailShare.body(link: link, note: link.note, includeNote: false), "A title Another line\n" + link.url)
        XCTAssertEqual(EmailShare.body(link: link, note: "  A thought\nfor you  ", includeNote: true), "A thought\nfor you\n\nA title Another line\n" + link.url)
        XCTAssertEqual(link.note, "Private saved note")
    }
    func testSwipeLocksDirectionAndRequiresIntentionalDistance() {
        var vertical = RowSwipe(); vertical.move(x: 2, y: 9); vertical.move(x: 200, y: 0)
        XCTAssertTrue(vertical.axis == .vertical)
        var horizontal = RowSwipe(); horizontal.move(x: -10, y: 2); horizontal.move(x: -170, y: 100)
        XCTAssertTrue(horizontal.axis == .horizontal)
        XCTAssertEqual(RowSwipe.finish(offset: horizontal.x), .archive)
        XCTAssertEqual(RowSwipe.finish(offset: -70), .archiveButton)
        XCTAssertEqual(RowSwipe.finish(offset: 180), .copy)
        XCTAssertEqual(RowSwipe.finish(offset: 60), .shareButtons)
        XCTAssertEqual(RowSwipe.finish(offset: 30), .closed)
        XCTAssertEqual(RowSwipe.finish(offset: -200, cancelled: true), .closed)
        XCTAssertEqual(RowSwipe.archiveIntentProgress(offset: -140), 0)
        XCTAssertEqual(RowSwipe.archiveIntentProgress(offset: -175), 0.5)
        XCTAssertEqual(RowSwipe.archiveIntentProgress(offset: -210), 1)
        XCTAssertEqual(RowSwipe.archiveIntentProgress(offset: -260), 1)
        XCTAssertEqual(RowSwipe.copyIntentProgress(offset: 140), 0)
        XCTAssertEqual(RowSwipe.copyIntentProgress(offset: 175), 0.5)
        XCTAssertEqual(RowSwipe.copyIntentProgress(offset: 210), 1)
        XCTAssertEqual(RowSwipe.copyIntentProgress(offset: 260), 1)
    }
    func testSiteIconURLsAndHTMLFallback() {
        let base = SiteIcon.origin("https://www.example.com/private/path?secret=token#part")!
        XCTAssertEqual(base.absoluteString, "https://www.example.com/")
        let html = """
        <link href="/style.css" rel="stylesheet">
        <link href='/touch.png' rel='apple-touch-icon'>
        <link REL="shortcut icon" HREF="/brand.png?v=1&amp;s=2">
        <link rel=icon href=//cdn.example.com/favicon.ico>
        <link rel=icon href="javascript:alert(1)">
        <meta property="og:image" content="https://example.com/article.jpg">
        """
        XCTAssertEqual(SiteIcon.declared(in: html, base: base).map(\.absoluteString), ["https://www.example.com/brand.png?v=1&s=2", "https://cdn.example.com/favicon.ico", "https://www.example.com/touch.png"])
        XCTAssertNil(SiteIcon.resolve("file:///tmp/icon.png", relativeTo: base))
        XCTAssertNil(SiteIcon.resolve("https://user:secret@example.com/icon", relativeTo: base))
        XCTAssertNil(SiteIcon.origin("javascript:alert(1)"))
    }
    func testIconMetadataSurvivesLibraryRoundTripAndLegacySaves() throws {
        var link = SavedLink(url: "https://example.com/article", title: "Article")
        link.iconURL = "https://cdn.example.com/icon.png"
        let data = try JSONEncoder().encode(link)
        try XCTAssertEqual(try JSONDecoder().decode(SavedLink.self, from: data).iconURL, link.iconURL)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "iconURL")
        let legacy = try JSONDecoder().decode(SavedLink.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.iconURL)
        var library = Library(); library.insert([link])
        var updated = legacy; updated.note = "Keep my note"
        library.saveAnnotated(updated)
        XCTAssertEqual(library.links[0].iconURL, link.iconURL)
        XCTAssertEqual(library.links[0].note, "Keep my note")
    }
    func testCaptureDeduplicatesWithinBatchAndAcrossSaves() {
        var library = Library()
        XCTAssertEqual(library.insert([
            SavedLink(url: "https://example.com/", title: "First title"),
            SavedLink(url: "https://EXAMPLE.com", title: "Another title"),
            SavedLink(url: "chrome://settings", title: "Settings")
        ]), 1)
        library.links[0].note = "Keep this note"
        library.links[0].isFavorite = true
        XCTAssertEqual(library.insert([SavedLink(url: "https://example.com", title: "New")]), 0)
        XCTAssertEqual(library.links[0].note, "Keep this note")
        XCTAssertTrue(library.links[0].isFavorite)
        XCTAssertEqual(library.links[0].title, "First title")
    }
    func testMeaningfulQueriesAndFragmentsArePreserved() {
        var library = Library()
        XCTAssertEqual(library.insert([
            SavedLink(url: "https://example.com/?q=one", title: "One"),
            SavedLink(url: "https://example.com/?q=two", title: "Two"),
            SavedLink(url: "https://example.com/#section", title: "Section")
        ]), 3)
    }
    func testRejectsUnsafeAndNonWebURLs() {
        for raw in ["javascript:alert(1)", "file:///tmp/private", "chrome://settings", "about:blank", "https://", "https://user:pass@example.com", "not a url"] {
            XCTAssertNil(Library.validatedURL(raw), raw)
        }
        XCTAssertNotNil(Library.validatedURL(" https://example.com/a?q=b#c \n"))
    }
    func testSearchIncludesNotesAndCollection() {
        var link = SavedLink(url: "https://example.com", title: "A good read", browser: "Safari", collection: "Inspiration")
        link.note = "A thought about typography"
        XCTAssertTrue(link.matches("TYPOGRAPHY")); XCTAssertTrue(link.matches("inspiration"))
        XCTAssertTrue(link.matches("safari")); XCTAssertFalse(link.matches("missing"))
    }
    func testKeywordSearchAcrossFieldsAndRanking() {
        var link = SavedLink(url: "https://example.com/type", title: "Café typography")
        link.note = "Use this for the launch"; link.tags = ["Design", "Research"]
        XCTAssertTrue(link.matches("cafe launch"))
        XCTAssertTrue(link.matches("typography #design"))
        XCTAssertFalse(link.matches("typography #des"))
        XCTAssertFalse(link.matches("cafe missing"))
        XCTAssertTrue(link.matches("   "))
        let titleScore = LinkSearch.score(query: "design", title: "Design systems", url: "https://example.com")!
        let noteScore = LinkSearch.score(query: "design", title: "A bookmark", url: "https://example.com", note: "Design systems")!
        XCTAssertTrue(titleScore > noteScore)
        XCTAssertNil(LinkSearch.score(query: "unrelated", title: "Design", url: "https://example.com"))
    }
    func testTagCountsIgnoreCaseAndDuplicateTags() {
        var first = SavedLink(url: "https://example.com/1", title: "One"); first.tags = ["Design", "design", "Work"]
        var second = SavedLink(url: "https://example.com/2", title: "Two"); second.tags = ["design"]
        let tags = TagSummary.summarize([first, second])
        XCTAssertEqual(tags.count, 2); XCTAssertEqual(tags.first?.count, 2)
        XCTAssertEqual(tags.first?.id, "design")
    }
    func testTagSummariesSortByLinkCountWithAlphabeticalTies() {
        var first = SavedLink(url: "https://example.com/1", title: "One"); first.tags = ["Alpha", "Work", "Design", "Article"]
        var second = SavedLink(url: "https://example.com/2", title: "Two"); second.tags = ["Work", "Design", "Article"]
        var third = SavedLink(url: "https://example.com/3", title: "Three"); third.tags = ["Design", "Article"]
        let tags = TagSummary.summarize([first, second, third])
        XCTAssertEqual(TagSummary.sorted(tags, by: .alphabetical).map(\.name), ["Alpha", "Article", "Design", "Work"])
        XCTAssertEqual(TagSummary.sorted(tags, by: .mostLinks).map(\.name), ["Article", "Design", "Work", "Alpha"])
    }
    func testDiskRoundTripAndMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LibraryFile(url: directory.appendingPathComponent("library.json"))
        try XCTAssertEqual(try file.load(), Library())
        var library = Library()
        library.insert([SavedLink(url: "https://example.com", title: "Unicode 🌿\nWith newline", collection: "Research")])
        library.links[0].note = "A persistent note"; library.links[0].isArchived = true
        try file.save(library)
        try XCTAssertEqual(try file.load(), library)
    }
    func testDateGroupingUsesLocalDaysAndNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 23))!
        var morning = SavedLink(url: "https://example.com/morning", title: "Morning")
        morning.createdAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 8))!
        var evening = SavedLink(url: "https://example.com/evening", title: "Evening"); evening.createdAt = now
        var yesterday = SavedLink(url: "https://example.com/yesterday", title: "Yesterday")
        yesterday.createdAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 23))!
        var old = SavedLink(url: "https://example.com/old", title: "Old")
        old.createdAt = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let groups = LinkDay.group([old, morning, yesterday, evening], now: now, calendar: calendar)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].label, "Today"); XCTAssertEqual(groups[1].label, "Yesterday")
        XCTAssertEqual(groups[0].links.map(\.title), ["Evening", "Morning"])
        XCTAssertTrue(groups[2].label.contains("2025"))
        XCTAssertTrue(LinkDay.group([], now: now, calendar: calendar).isEmpty)
    }
    func testCaptureFindsBrowserFromOtherAppsAndAfterRestart() {
        let supported: Set<String> = ["Safari", "Chrome"]
        func target(_ front: String?, _ running: Set<String>, _ remembered: String?, _ visible: [String] = []) -> String? {
            BrowserTarget.resolve(front: front, supported: supported, running: running, remembered: remembered, visible: visible)
        }
        XCTAssertEqual(target("Chrome", supported, "Safari"), "Chrome")
        XCTAssertEqual(target("SaveNest", supported, "Chrome"), "Chrome")
        XCTAssertEqual(target("ChatGPT", supported, "Chrome"), "Chrome")
        XCTAssertEqual(target(nil, supported, "Safari"), "Safari")
        XCTAssertEqual(target("SaveNest", supported, nil, ["ChatGPT", "Chrome", "Safari"]), "Chrome")
        XCTAssertEqual(target("SaveNest", ["Safari"], "Chrome"), "Safari")
        XCTAssertNil(target("SaveNest", [], "Chrome"))
        XCTAssertNil(target("SaveNest", supported, nil))
        XCTAssertNil(target("Unknown", ["Unknown"], "Unknown", ["Unknown"]))
    }
    func testLegacyLibraryAndTagsRoundTrip() throws {
        var link = SavedLink(url: "https://example.com", title: "Old saved link")
        link.note = "Keep my note"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as! [String: Any]
        json.removeValue(forKey: "tags")
        let legacy = try JSONDecoder().decode(SavedLink.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.tags, []); XCTAssertEqual(legacy.note, "Keep my note")
        link.tags = SavedLink.parseTags(" #Design, read later, design, , Work ")
        XCTAssertEqual(link.tags, ["Design", "read later", "Work"])
        let restored = try JSONDecoder().decode(SavedLink.self, from: JSONEncoder().encode(link))
        XCTAssertEqual(restored, link); XCTAssertTrue(restored.matches("READ LATER"))
    }
    func testAnnotationOfExistingLinkPreservesIdentityAndState() {
        var library = Library()
        var original = SavedLink(url: "https://example.com/", title: "Original")
        original.isArchived = true; original.isFavorite = true
        library.insert([original])
        var captured = SavedLink(url: "https://example.com", title: "Edited title")
        captured.note = "My note"; captured.tags = ["Design", "design"]
        XCTAssertTrue(library.saveAnnotated(captured))
        XCTAssertEqual(library.links.count, 1)
        XCTAssertEqual(library.links[0].id, original.id)
        XCTAssertEqual(library.links[0].createdAt, original.createdAt)
        XCTAssertTrue(library.links[0].isArchived); XCTAssertTrue(library.links[0].isFavorite)
        XCTAssertEqual(library.links[0].note, "My note"); XCTAssertEqual(library.links[0].tags, ["Design"])
    }
    func testSocialTitlesPreferContentAndHaveSpecificFallbacks() {
        XCTAssertEqual(LinkTitle.best(url: "https://instagram.com/p/ABC123/", browserTitle: "Instagram", metadata: ["ogTitle": "A quiet morning in the mountains"]), "A quiet morning in the mountains")
        XCTAssertEqual(LinkTitle.best(url: "https://x.com/anna/status/123", browserTitle: "X", metadata: ["post": "A useful idea\n for next week", "ogTitle": "X"]), "A useful idea for next week")
        XCTAssertEqual(LinkTitle.best(url: "https://linkedin.com/posts/alex-design", browserTitle: "LinkedIn", metadata: ["description": "How we improved the onboarding experience"]), "How we improved the onboarding experience")
        XCTAssertEqual(LinkTitle.best(url: "https://instagram.com/reel/ABC123/", browserTitle: "Instagram"), "Instagram reel · ABC123")
        XCTAssertEqual(LinkTitle.best(url: "https://x.com/anna/status/123", browserTitle: "(2) X"), "@anna on X · 123")
        XCTAssertEqual(LinkTitle.best(url: "https://example.com/article", browserTitle: "A good article"), "A good article")
        XCTAssertEqual(LinkTitle.best(url: "https://linkedin.com/in/anna", browserTitle: "LinkedIn", metadata: ["ogTitle": "LinkedIn: Log In or Sign Up"]), "LinkedIn · anna")
        XCTAssertEqual(LinkTitle.clean(String(repeating: "a", count: 300)).count, 180)
    }
    func testSubscriptionStatusRequiresFreshServerVerification() throws {
        let oldSubscription = Data(#"{"active":false,"status":"inactive","mode":"live"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(SaveNestAccount.Subscription.self, from: oldSubscription).billingReady)
        let readySubscription = Data(#"{"active":false,"status":"inactive","mode":"live","billingReady":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(SaveNestAccount.Subscription.self, from: readySubscription).billingReady)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let user = SaveNestAccount.User(id: "user", name: "Dima", email: "dima@example.com")
        func account(active: Bool = true, status: String = "active", mode: String = "sandbox", plan: String? = "monthly", end: Double? = 1_800_010_000) -> SaveNestAccount {
            SaveNestAccount(user: user, subscription: .init(active: active, plan: plan, status: status, mode: mode, renewsAt: end))
        }
        for status in ["active", "past_due", "unpaid", "paused", "trialing", "incomplete"] {
            let legacy = account(active: false, status: status, plan: nil)
            XCTAssertTrue(AccountAccess.blocksNewCheckout(legacy))
            XCTAssertTrue(AccountAccess.canManageBilling(legacy))
            XCTAssertFalse(AccountAccess.hasCurrentSubscription(legacy, now: now))
        }
        for status in ["canceled", "incomplete_expired"] {
            XCTAssertFalse(AccountAccess.blocksNewCheckout(account(active: false, status: status, plan: nil)))
            XCTAssertTrue(AccountAccess.canManageBilling(account(active: false, status: status, plan: nil)))
        }
        XCTAssertFalse(AccountAccess.canManageBilling(account(active: false, status: "inactive", plan: nil)))
        XCTAssertTrue(AccountAccess.canManageBilling(account(active: false, status: "unavailable", plan: nil)))
        XCTAssertTrue(AccountAccess.hasVerifiedSubscription(account(), verifiedAt: now, now: now))
        XCTAssertTrue(AccountAccess.hasVerifiedSubscription(account(status: "trialing"), verifiedAt: now, now: now))
        XCTAssertTrue(AccountAccess.hasVerifiedSubscription(account(mode: "live", plan: "yearly"), verifiedAt: now.addingTimeInterval(-119), now: now))
        XCTAssertTrue(AccountAccess.hasCurrentSubscription(account(), now: now))
        XCTAssertTrue(AccountAccess.hasCurrentSubscription(account(status: "trialing"), now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(active: false, status: "trialing"), verifiedAt: now, now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(mode: "live", plan: "weekly"), verifiedAt: now.addingTimeInterval(-119), now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(), verifiedAt: nil, now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(), verifiedAt: now.addingTimeInterval(-120), now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(), verifiedAt: now.addingTimeInterval(1), now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(active: false), verifiedAt: now, now: now))
        for status in ["canceled", "past_due", "unpaid", "incomplete"] {
            XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(status: status), verifiedAt: now, now: now))
        }
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(mode: "preview"), verifiedAt: now, now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(plan: nil), verifiedAt: now, now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(end: nil), verifiedAt: now, now: now))
        XCTAssertFalse(AccountAccess.hasVerifiedSubscription(account(end: now.timeIntervalSince1970), verifiedAt: now, now: now))
        XCTAssertFalse(AccountAccess.hasCurrentSubscription(account(active: false), now: now))
        XCTAssertFalse(AccountAccess.hasCurrentSubscription(account(status: "past_due"), now: now))
        XCTAssertFalse(AccountAccess.hasCurrentSubscription(account(end: now.timeIntervalSince1970), now: now))
        let encoded = try JSONEncoder().encode(account())
        try XCTAssertEqual(JSONDecoder().decode(SaveNestAccount.self, from: encoded), account())
    }
    func testCheckoutUsesExistingSubscriptionForPaymentRecovery() {
        let user = SaveNestAccount.User(id: "user", name: "Dima", email: "dima@example.com")
        func account(_ status: String, plan: String? = "monthly") -> SaveNestAccount {
            SaveNestAccount(user: user, subscription: .init(active: false, plan: plan, status: status, mode: "sandbox", renewsAt: nil))
        }
        for status in ["active", "past_due", "unpaid", "paused", "trialing", "incomplete"] {
            XCTAssertTrue(AccountAccess.blocksNewCheckout(account(status)))
        }
        for status in ["canceled", "incomplete_expired", "inactive"] {
            XCTAssertFalse(AccountAccess.blocksNewCheckout(account(status)))
        }
        XCTAssertFalse(AccountAccess.blocksNewCheckout(account("inactive", plan: nil)))
        XCTAssertFalse(AccountAccess.blocksNewCheckout(nil))
    }
    func testSignInCallbackRejectsForgedOrAmbiguousURLs() {
        let state = String(repeating: "s", count: 43)
        let code = String(repeating: "c", count: 43)
        XCTAssertEqual(AccountAccess.callbackCode(URL(string: "savenest://auth/callback?code=\(code)&state=\(state)")!, expectedState: state), code)
        for raw in [
            "savenest://auth/callback?code=\(code)&state=\(String(repeating: "x", count: 43))",
            "https://auth/callback?code=\(code)&state=\(state)",
            "savenest://evil/callback?code=\(code)&state=\(state)",
            "savenest://auth/other?code=\(code)&state=\(state)",
            "savenest://auth/callback?code=&state=\(state)",
            "savenest://auth/callback?code=\(code)&code=\(code)&state=\(state)",
            "savenest://auth/callback?code=\(code)&state=\(state)&state=\(state)",
            "savenest://auth/callback?code=\(code)&state=\(state)#fragment",
            "savenest://user@auth/callback?code=\(code)&state=\(state)"
        ] { XCTAssertNil(AccountAccess.callbackCode(URL(string: raw)!, expectedState: state), raw) }
    }
    func testReferralCallbackAcceptsOnlyOneSafeCode() {
        XCTAssertEqual(AccountAccess.referralCode(URL(string: "savenest://invite/redeem?code=snabc23456")!), "SNABC23456")
        for raw in [
            "https://invite/redeem?code=SNABC23456",
            "savenest://evil/redeem?code=SNABC23456",
            "savenest://invite/other?code=SNABC23456",
            "savenest://invite/redeem?code=bad",
            "savenest://invite/redeem?code=SNABC23456&code=SNABC23456",
            "savenest://invite/redeem?code=SNABC23456#fragment"
        ] { XCTAssertNil(AccountAccess.referralCode(URL(string: raw)!), raw) }
    }
    func testPendingNativeCallbacksAreSingleUseAndBoundToStateAndAccount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = String(repeating: "s", count: 43)
        let verifier = String(repeating: "v", count: 43)
        let code = String(repeating: "c", count: 43)
        var signIn = PendingEmailSignIn(verifier: verifier, state: state, email: "dima@example.com", name: "Dima", now: now)
        let authURL = URL(string: "savenest://auth/callback?code=\(code)&state=\(state)")!
        XCTAssertEqual(signIn.consume(authURL, now: now.addingTimeInterval(1)), code)
        XCTAssertNil(signIn.consume(authURL, now: now.addingTimeInterval(2)))

        var billing = PendingBillingReturn(state: state, userID: "user-one", flow: .checkout, now: now)
        let returnURL = URL(string: "savenest://billing/return?flow=checkout&status=success&state=\(state)")!
        XCTAssertNil(billing.consume(returnURL, userID: "user-two", now: now.addingTimeInterval(1)))
        XCTAssertEqual(billing.consume(returnURL, userID: "user-one", now: now.addingTimeInterval(1)), NativeBillingReturn(flow: .checkout, status: .success))
        XCTAssertNil(billing.consume(returnURL, userID: "user-one", now: now.addingTimeInterval(2)))
    }
    @MainActor func testBillingPollFindsDelayedPaymentWithoutCallback() async {
        var time = Date(timeIntervalSince1970: 1_000)
        let deadline = time.addingTimeInterval(60)
        var checks = 0
        let result = await BillingAccessPoll.run(until: deadline, now: { time }, sleep: { time = time.addingTimeInterval($0) }) {
            checks += 1
            // Stripe first reports unpaid, then temporary unavailability, then verified access.
            return checks == 3
        }
        XCTAssertTrue(result); XCTAssertEqual(checks, 3)
        XCTAssertEqual(time.timeIntervalSince1970, 1_010)
    }
    @MainActor func testBillingPollTimesOutWithoutGrantingAccess() async {
        var time = Date(timeIntervalSince1970: 1_000)
        let deadline = time.addingTimeInterval(12)
        var checks = 0
        let result = await BillingAccessPoll.run(until: deadline, now: { time }, sleep: { time = time.addingTimeInterval($0) }) {
            checks += 1; return false
        }
        XCTAssertFalse(result); XCTAssertEqual(checks, 3); XCTAssertEqual(time, deadline)
    }
    @MainActor func testBillingPollStopsOnCancellation() async {
        var checks = 0
        let result = await BillingAccessPoll.run(until: Date().addingTimeInterval(60), sleep: { _ in throw CancellationError() }) {
            checks += 1; return false
        }
        XCTAssertFalse(result); XCTAssertEqual(checks, 1)
    }
    func testCorruptOrFutureLibraryThrowsWithoutChangingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("not JSON".utf8); try corrupt.write(to: url)
        XCTAssertThrowsError(try LibraryFile(url: url).load())
        try XCTAssertEqual(try Data(contentsOf: url), corrupt)
        var future = Library(); future.version = 2
        try LibraryFile(url: url).save(future)
        XCTAssertThrowsError(try LibraryFile(url: url).load())
    }
}

// A dependency-free test runner also works with Command Line Tools (no Xcode/XCTest).
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) rethrows {
    let a = try lhs(), b = try rhs(); precondition(a == b, "Expected \(a) == \(b)")
}
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertFalse(_ value: Bool) { precondition(!value) }
func XCTAssertNil<T>(_ value: T?, _ message: String = "") { precondition(value == nil, message) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression() } catch { return }; preconditionFailure("Expected an error")
}
@main enum Checks {
    @MainActor static func main() async throws {
        checkTabWorkspace()
        try checkBrowserHistory()
        try runNoteFileChecks()
        try runCloudLibraryChecks()
        try runAutomationLibraryChecks()
        let tests = LibraryTests()
        tests.testTabCleanupPlanningIsConservativeAndDomainScoped()
        try tests.testBrowserTabPayloadsDecodeAndSaveTogether()
        tests.testCaptureDeduplicatesWithinBatchAndAcrossSaves()
        tests.testMeaningfulQueriesAndFragmentsArePreserved()
        tests.testRejectsUnsafeAndNonWebURLs()
        tests.testSearchIncludesNotesAndCollection()
        tests.testKeywordSearchAcrossFieldsAndRanking()
        tests.testTagCountsIgnoreCaseAndDuplicateTags()
        tests.testTagSummariesSortByLinkCountWithAlphabeticalTies()
        try tests.testDiskRoundTripAndMissingFile()
        try tests.testCorruptOrFutureLibraryThrowsWithoutChangingFile()
        tests.testDateGroupingUsesLocalDaysAndNewestFirst()
        tests.testCaptureFindsBrowserFromOtherAppsAndAfterRestart()
        try tests.testLegacyLibraryAndTagsRoundTrip()
        tests.testAnnotationOfExistingLinkPreservesIdentityAndState()
        tests.testSocialTitlesPreferContentAndHaveSpecificFallbacks()
        try tests.testSubscriptionStatusRequiresFreshServerVerification()
        tests.testSignInCallbackRejectsForgedOrAmbiguousURLs()
        tests.testReferralCallbackAcceptsOnlyOneSafeCode()
        tests.testPendingNativeCallbacksAreSingleUseAndBoundToStateAndAccount()
        tests.testCheckoutUsesExistingSubscriptionForPaymentRecovery()
        await tests.testBillingPollFindsDelayedPaymentWithoutCallback()
        await tests.testBillingPollTimesOutWithoutGrantingAccess()
        await tests.testBillingPollStopsOnCancellation()
        tests.testArchiveUndoPreservesEditsAndExistingArchive()
        tests.testTagManagementRenamesAndDeletesAcrossLinks()
        try tests.testLegacyReadStateIsIgnored()
        tests.testEmptyArchiveDeletesOnlyConfirmedStillArchivedLinks()
        tests.testEmailShareOnlyIncludesExplicitlyChosenNote()
        tests.testSwipeLocksDirectionAndRequiresIntentionalDistance()
        tests.testSiteIconURLsAndHTMLFallback()
        try tests.testIconMetadataSurvivesLibraryRoundTripAndLegacySaves()
        tests.testClipboardRequiresSingleSafeURL()
        tests.testImportanceLearningRequiresEvidenceAndHonorsCorrections()
        tests.testAutoTaggingMatchesExistingTagsConservatively()
        tests.testAutoTaggingLearnsTitleMappingsWithAgreement()
        tests.testAutoTaggingUsesDomainHistoryAndStableRanking()
        tests.testTagCompletionSelectsFirstFilteredSuggestion()
        try tests.testImportanceMigrationAndBackup()
        try tests.testAnalyticsOptOutAndPayloadBoundary()
        print("Passed 40 SaveNest checks")
    }
}
