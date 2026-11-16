#if DEBUG
import AppKit
import SaveNestCore

/// Runs before AppModel startup with `--ui-preview --services-checks`.
/// Uses disposable request pasteboards and the in-memory preview library only.
@MainActor
enum ServicesSelfChecks {
    private struct Failed: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failed(errorDescription: "Services check failed: " + message) }
    }

    static func run() async throws {
        guard AppLaunch.isPreview else { throw Failed(errorDescription: "Services checks require --ui-preview.") }
        try await checkParsing()
        try await checkExplicitSaveAndDuplicates()
        try await checkDraftProtection()
        print("Passed Services checks: request pasteboards, URL validation, URL/text input, existing links, draft protection, cancellation, and explicit save.")
    }

    private static func board(_ text: String, type: NSPasteboard.PasteboardType = .string) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.declareTypes([type], owner: nil)
        board.setString(text, forType: type)
        return board
    }

    @discardableResult
    private static func invoke(_ board: NSPasteboard, _ provider: ServicesProvider) -> String? {
        var error: NSString?
        provider.addToSaveNest(board, userData: "", error: &error)
        return error.map { $0 as String }
    }

    private static func checkParsing() async throws {
        let model = AppModel()
        model.showCaptureEditor = { _ in }
        let provider = ServicesProvider(model: model)
        let before = model.library
        let invalid: [(String, String)] = [
            ("empty", ""),
            ("whitespace", "  \n "),
            ("prose", "Read this https://services-fixture.test/prose"),
            ("multiple", "https://services-fixture.test/one\nhttps://services-fixture.test/two"),
            ("credentials", "https://user:secret@services-fixture.test/private"),
            ("unsupported scheme", "ftp://services-fixture.test/file"),
            ("missing host", "https://"),
            ("oversized", "https://services-fixture.test/" + String(repeating: "a", count: 8192))
        ]
        for (name, text) in invalid {
            let error = invoke(board(text), provider)
            try expect(error != nil, "\(name) input returns a service error")
            try expect(model.draft == nil, "\(name) input opens no editor")
            try expect(model.library == before, "\(name) input does not change the library")
        }

        let urlText = "https://services-fixture.test/url-type?q=1"
        let urlBoard = board(urlText, type: .URL)
        try expect(invoke(urlBoard, provider) == nil, "public.url input opens the editor")
        let parsed = ClipboardLink.parse(urlText)!
        try expect(model.draft?.link.url == parsed.absoluteString, "URL-type input preserves the address")
        try expect(model.draft?.action == .note && model.draft?.closeTarget == nil, "Services opens a note draft with no tab target")
        try expect(model.draft?.link.browser == "Services", "new Services links record their source")
        try expect(model.draft?.link.title == LinkTitle.best(url: parsed.absoluteString, browserTitle: ""), "new Services links use the title fallback")
        try expect(urlBoard.string(forType: .URL) == urlText, "service invocation leaves the request pasteboard intact")
        model.cancelDraft()

        let textTypes: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("NSStringPboardType")
        ]
        for (index, type) in textTypes.enumerated() {
            let text = "https://services-fixture.test/text-type/\(index)"
            let request = board(text, type: type)
            try expect(invoke(request, provider) == nil, "\(type.rawValue) input opens the editor")
            try expect(model.draft?.link.url == ClipboardLink.parse(text)?.absoluteString, "\(type.rawValue) input preserves the address")
            try expect(request.string(forType: type) == text, "\(type.rawValue) request pasteboard is intact")
            model.cancelDraft()
        }

        let normalChangeCount = NSPasteboard.general.changeCount
        let serviceRequest = board("https://services-fixture.test/isolated", type: .string)
        try expect(invoke(serviceRequest, provider) == nil, "isolated request opens the editor")
        try expect(NSPasteboard.general.changeCount == normalChangeCount,
                   "Services reads only the request pasteboard, not the normal clipboard")
        model.cancelDraft()

        let multipleItems = NSPasteboard.withUniqueName()
        defer { multipleItems.releaseGlobally() }
        let items = ["https://example.com/one", "https://example.com/two"].map { value -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString(value, forType: .URL); return item
        }
        multipleItems.writeObjects(items)
        try expect(invoke(multipleItems, provider) != nil && model.draft == nil, "multiple pasteboard items cannot silently save the first URL")
    }

    private static func checkExplicitSaveAndDuplicates() async throws {
        let model = AppModel()
        var shown: CaptureDraft?
        var closed = 0
        model.showCaptureEditor = { shown = $0 }
        model.closeCaptureEditor = { closed += 1 }
        let provider = ServicesProvider(model: model)

        let newText = "https://services-fixture.test/new?from=services"
        let before = model.library
        try expect(invoke(board(newText, type: .URL), provider) == nil, "new link opens the editor")
        guard let newDraft = model.draft else { throw Failed(errorDescription: "Services did not create a draft.") }
        try expect(shown?.id == newDraft.id, "the AppDelegate editor callback receives the draft")
        try expect(newDraft.link.note.isEmpty && newDraft.link.tags.isEmpty, "new Services links start without notes or tags")
        try expect(model.library == before, "opening the editor does not mutate the library")
        model.cancelDraft()
        try expect(model.draft == nil && model.library == before, "cancelling leaves the library untouched")
        try expect(closed == 1, "cancelling closes the editor")

        let existingText = "https://SERVICES-fixture.test/"
        let added = await model.add(url: existingText, title: "Existing title", collection: "Inbox", note: "Existing note", tags: ["Reference"])
        try expect(added, "fixture link saves")
        guard let existing = model.library.links.first(where: { Library.identity($0.url) == Library.identity(existingText) }) else {
            throw Failed(errorDescription: "Fixture link was not stored.")
        }
        let withExisting = model.library
        try expect(invoke(board("https://services-fixture.test", type: .string), provider) == nil, "existing identity opens the editor")
        guard let existingDraft = model.draft else { throw Failed(errorDescription: "Existing link did not open a draft.") }
        try expect(existingDraft.link.id == existing.id, "existing identity loads the saved record")
        try expect(existingDraft.link.note == "Existing note" && existingDraft.link.tags == ["Reference"], "existing note and tags load")
        try expect(existingDraft.link.browser == existing.browser && existingDraft.link.title == existing.title, "existing title and source load")
        try expect(model.library == withExisting, "opening an existing link does not mutate the library")
        model.cancelDraft()

        let saveText = "https://services-fixture.test/save-from-services"
        try expect(invoke(board(saveText, type: .string), provider) == nil, "link for explicit save opens the editor")
        guard var draft = model.draft else { throw Failed(errorDescription: "Services did not create a save draft.") }
        try expect(!model.library.links.contains { Library.identity($0.url) == Library.identity(saveText) }, "nothing is saved before confirmation")
        draft.link.note = "Saved from Services"
        draft.link.tags = ["Services", "Reference"]
        let closedBeforeSave = closed
        let didSave = await model.saveDraft(draft.link)
        try expect(didSave, "explicit Save commits the in-memory preview library")
        guard let saved = model.library.links.first(where: { Library.identity($0.url) == Library.identity(saveText) }) else {
            throw Failed(errorDescription: "Explicit Save did not store the link.")
        }
        try expect(saved.note == "Saved from Services" && saved.tags == ["Services", "Reference"], "explicit Save keeps note and tags")
        try expect(saved.browser == "Services", "saved Services links keep their source")
        try expect(model.draft == nil && closed == closedBeforeSave + 1, "explicit Save closes the editor")
    }

    private static func checkDraftProtection() async throws {
        let model = AppModel()
        var shown = 0
        model.showCaptureEditor = { _ in shown += 1 }
        model.autoTaggingEnabled = false
        let provider = ServicesProvider(model: model)
        model.beginDraft(SavedLink(url: "https://services-fixture.test/original-draft", title: "Original"), action: .note)
        guard let original = model.draft else { throw Failed(errorDescription: "Original draft was not created.") }
        let error = invoke(board("https://services-fixture.test/second-request", type: .URL), provider)
        try expect(error?.contains("Finish or cancel") == true, "second service request returns a helpful error")
        try expect(model.draft?.id == original.id && model.draft?.link.url == original.link.url, "active capture draft remains intact")
        try expect(shown == 1, "second request does not replace the editor")
        model.cancelDraft()

        model.tabSelection = TabSelectionDraft(links: [SavedLink(url: "https://services-fixture.test/selection", title: "Selection")])
        let selectionError = invoke(board("https://services-fixture.test/third-request", type: .string), provider)
        try expect(selectionError?.contains("Finish or cancel") == true, "tab selection also rejects a service request")
        try expect(model.tabSelection != nil && model.draft == nil, "active tab selection remains intact")
    }
}
#endif
