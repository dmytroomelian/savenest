import AppKit
import Combine
import SaveNestCore
import SwiftUI

/// Local JSON-lines transport. The native process remains the only library writer;
/// account credentials and authorization never cross into the web renderer.
@MainActor
final class ElectronBridge {
    static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("SaveNest.Settings")
    private let model: AppModel
    private var subscriptions = Set<AnyCancellable>()
    private var pendingSnapshot: DispatchWorkItem?
    private var readerSources: [String: [String: Any]] = [:]
    private var previousApplication: NSRunningApplication?
    private(set) var panelVisible = false

    init(model: AppModel) { self.model = model }

    static func failStartup(_ message: String) { write(["event": "fatal", "message": message]) }
    static func startupConflict(existingApplication: URL) {
        write(["event": "startup-conflict", "existingAppPath": existingApplication.path])
    }
    private static func write(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
    func event(_ name: String) { Self.write(["event": name]) }

    func start() {
        // A release helper must never silently treat a requested preview as a live session.
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") && !model.isPreview {
            Self.failStartup("Preview requires a debug helper. Run npm run build:native first.")
            NSApp.terminate(nil); return
        }
        model.hotkey.action = { [weak self] action in
            guard let self else { return }
            if action == .search { self.event("toggle") }
            else if action == .reader { self.event("readerCurrent") }
            else { self.model.capture(action: action, sourceApplication: self.panelVisible ? self.previousApplication : nil) }
        }
        model.showCaptureEditor = { [weak self] _ in self?.event("show"); self?.scheduleSnapshot() }
        model.closeCaptureEditor = { [weak self] in self?.event("editorSaved") }
        model.showTabSelection = { [weak self] _ in self?.event("show"); self?.scheduleSnapshot() }
        model.closeTabSelection = { [weak self] in self?.event("selectionClosed") }
        model.launchAtLogin.hostRefresh = { [weak self] in self?.event("loginItemRefresh") }
        model.launchAtLogin.hostSet = { enabled in Self.write(["event": "loginItemSet", "enabled": enabled]) }
        model.updater.requestHostCheck = { [weak self] in self?.event("checkForUpdates") }
        model.objectWillChange.sink { [weak self] in self?.scheduleSnapshot() }.store(in: &subscriptions)
        model.updater.objectWillChange.sink { [weak self] in self?.scheduleSnapshot() }.store(in: &subscriptions)
        model.notes.objectWillChange.sink { [weak self] in self?.scheduleSnapshot() }.store(in: &subscriptions)
        model.cloud.objectWillChange.sink { [weak self] in self?.scheduleSnapshot() }.store(in: &subscriptions)
        model.socialCapture.objectWillChange.sink { [weak self] in self?.scheduleSnapshot() }.store(in: &subscriptions)
        model.tabSearch.objectWillChange.sink { [weak self] in self?.scheduleSnapshot() }.store(in: &subscriptions)
        model.$library.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] library in
            self?.model.tabSearch.updateLibrary(library.links)
            self?.event("activityChanged")
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSnapshot() }.store(in: &subscriptions)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let bytes = FileHandle.standardInput.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                if buffer.count > 1_048_576 { break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    Task { @MainActor [weak self] in await self?.receive(line) }
                }
            }
            // Parent closed its pipe or exited; do not leave global shortcuts running.
            Task { @MainActor in NSApp.terminate(nil) }
        }
        snapshot()
    }

    private func scheduleSnapshot() {
        guard pendingSnapshot == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSnapshot = nil; self?.snapshot()
        }
        pendingSnapshot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func snapshot() {
        let search = model.tabSearch
        // Plain Settings can stay open for an update. Every other native window,
        // sheet, editable field, and active shortcut recorder still blocks restart.
        let hasBlockingWindow = NSApp.windows.contains { $0.isVisible && !isPlainSettingsWindow($0) }
        let canRestartForUpdate = !hasBlockingWindow && NSApp.modalWindow == nil
            && model.draft == nil && model.tabSelection == nil
            && !model.showingAdd && !model.showingTags && model.sharingLink == nil
            && model.cleanupReview == nil && !model.isCapturing && !model.isCleaningTabs
            && !search.busy && !model.account.isBusy && !model.account.isSigningIn && !model.cloud.isBusy
            && !model.socialCapture.isBusy
        let rows: [[String: Any]] = search.results.prefix(200).map { item in
            var row: [String: Any] = [
                "id": item.id, "title": item.title, "url": item.url, "domain": item.domain,
                "isOpen": item.tab != nil, "isSaved": item.link != nil,
                "isHistory": item.history != nil,
                "browser": item.tab?.browserName ?? item.link?.browser ?? item.history?.browser ?? "",
                "profile": item.history?.profile ?? "",
                "note": item.link?.note ?? "", "tags": item.link?.tags ?? [],
                "favorite": item.link?.isFavorite ?? false, "archived": item.link?.isArchived ?? false,
                "revision": item.link.map { AutomationLibrary.revision($0) } ?? "missing",
                "context": String(item.context.prefix(400))
            ]
            if let date = item.link?.createdAt { row["createdAt"] = ISO8601DateFormatter().string(from: date) }
            if let date = item.history?.lastVisited { row["lastVisited"] = ISO8601DateFormatter().string(from: date) }
            return row
        }
        let shortcuts: [[String: Any]] = CaptureAction.allCases.map { action in
            // AppModel has already resolved stored bindings and defaults. A missing
            // or unassigned entry must not advertise a shortcut that is not registered.
            let shortcut = model.shortcuts[action]
            let assigned = shortcut?.isAssigned == true
            return [
                "id": action.rawValue, "title": action.title,
                "key": assigned ? shortcut?.label ?? "" : "", "assigned": assigned,
                "error": model.shortcutErrors[action] ?? ""
            ]
        }
        let historySources: [[String: Any]] = search.historySources.map { source in
            [
                "browser": source.source.browser, "profile": source.source.profile,
                "count": source.count, "issue": source.issue ?? ""
            ]
        }
        var captureDraft: Any = NSNull()
        if let draft = model.draft {
            captureDraft = linkFields(draft.link)
        }
        var captureSelection: Any = NSNull()
        if let selection = model.tabSelection {
            let links: [[String: Any]] = selection.links.map(linkFields)
            captureSelection = ["id": selection.id.uuidString, "links": links] as [String: Any]
        }

        // Keep expressions small for the Swift compiler shipped with older Xcode versions.
        var state: [String: Any] = [:]
        state["rows"] = rows
        state["totalCount"] = search.results.count
        state["query"] = search.query
        state["scope"] = search.scope.rawValue
        state["resultsQuery"] = search.resultsQuery
        state["resultsScope"] = search.resultsScope.rawValue
        state["loading"] = search.loading
        state["loadingContext"] = search.loadingContext
        state["contextUnavailable"] = search.contextUnavailable
        state["busy"] = search.busy
        state["message"] = model.error ?? search.message ?? model.toast?.message ?? ""
        state["error"] = model.error != nil
        state["preview"] = model.isPreview
        state["appearance"] = AppAppearance.saved.rawValue
        state["canUndo"] = model.canUndoLastAction
        state["canSave"] = model.canWriteLibrary
        state["canRestartForUpdate"] = canRestartForUpdate
        state["updater"] = model.updater.hostStatus
        let indicator = model.cloud.indicator
        state["syncStatus"] = ["state": indicator.rawValue, "label": indicator.label]
        state["onboarding"] = model.showingOnboarding
        state["browserAccessExplained"] = model.isPreview || BrowserAccess.isExplained
        state["analyticsEnabled"] = model.analyticsEnabled
        state["showUsageNotice"] = model.analyticsEnabled && !model.hasSeenUsageNotice
        state["launcherShortcut"] = (model.shortcuts[.search] ?? CaptureAction.search.defaultShortcut).label
        state["shortcutError"] = model.shortcutErrors[.search] ?? ""
        state["shortcuts"] = shortcuts
        state["openCount"] = search.tabs.count
        state["savedCount"] = model.activeCount
        state["historyCount"] = search.history.count
        state["historyEnabled"] = search.historyEnabled
        state["loadingHistory"] = search.loadingHistory
        state["historySources"] = historySources
        state["captureDraft"] = captureDraft
        state["captureSelection"] = captureSelection
        state["tags"] = model.allTags
        state["notesStatus"] = model.notes.status()
        state["socialCapture"] = model.socialCapture.snapshot
        Self.write(["event": "state", "state": state])
    }

    private func isPlainSettingsWindow(_ window: NSWindow) -> Bool {
        guard window.identifier == Self.settingsWindowIdentifier,
              model.section == .settings, window.attachedSheet == nil else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
        func isRecording(in view: NSView) -> Bool {
            if let recorder = view as? RecorderButton, recorder.recording { return true }
            return view.subviews.contains { isRecording(in: $0) }
        }
        return window.contentView.map { !isRecording(in: $0) } ?? false
    }

    private func linkFields(_ link: SavedLink) -> [String: Any] {
        ["id": link.id.uuidString, "title": link.title, "url": link.url, "note": link.note, "tags": link.tags]
    }

    private struct Request: Decodable {
        let id: Int
        let command: String
        var ids: [String]?
        var query: String?
        var scope: String?
        var url: String?
        var title: String?
        var note: String?
        var tags: [String]?
        var action: String?
        var enabled: Bool?
        var updateState: String?
        var available: Bool?
        var message: String?
        var documentId: String?
        var text: String?
        var revision: String?
        var year: Int?
        var kind: String?
        var day: String?
        var offset: Int?
        var limit: Int?
    }

    private func receive(_ data: Data) async {
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        do {
            if let result = try await performReader(request) {
                Self.write(["id": request.id, "ok": true, "result": result])
            } else {
                try await perform(request)
                Self.write(["id": request.id, "ok": true])
            }
        } catch {
            Self.write(["id": request.id, "ok": false, "error": error.localizedDescription])
        }
        if !["siteIcon", "activity"].contains(request.command) { scheduleSnapshot() }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func rememberReaderSource(_ source: [String: Any]) {
        guard let url = source["url"] as? String else { return }
        if readerSources.count >= 64 { readerSources.removeAll() }
        readerSources[url] = source
    }

    private func performReader(_ request: Request) async throws -> [String: Any]? {
        switch request.command {
        case "activity":
            guard let year = request.year else { throw Failure(message: "Choose an activity year.") }
            let result = try LibraryActivity.query(library: model.library, year: year,
                kind: request.kind ?? "all", day: request.day,
                offset: request.offset ?? 0, limit: request.limit ?? 100)
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        case "siteIcon":
            guard let url = request.url,
                  let item = model.tabSearch.results.first(where: { $0.url == url }) else { return [:] }
            guard let data = await SiteIconLoader.shared.image(page: url, hint: item.link?.iconURL) else { return [:] }
            return ["dataURL": "data:image/png;base64," + data.base64EncodedString()]
        case "readerCurrent":
            let sourceApplication = panelVisible ? previousApplication : NSWorkspace.shared.frontmostApplication
            guard model.readerPreview || BrowserAccess.confirm() else { throw Failure(message: "Browser access was skipped. You can paste a link into Savenest instead.") }
            var source = try await ReaderCapture.current(using: model.captureService, sourceApplication: sourceApplication, preview: model.readerPreview)
            if let url = source["url"] as? String {
                source["quickNote"] = model.library.links.first(where: { Library.identity($0.url) == Library.identity(url) })?.note ?? ""
            }
            rememberReaderSource(source)
            source.removeValue(forKey: "readerTarget")
            return source
        case "readerOpen":
            guard let id = request.ids?.first, let item = model.tabSearch.results.first(where: { $0.id == id }) else {
                throw Failure(message: "This page changed. Refresh the list and try again.")
            }
            var source = await ReaderCapture.selected(item, preview: model.readerPreview)
            source["quickNote"] = item.link?.note ?? ""
            rememberReaderSource(source)
            source.removeValue(forKey: "readerTarget")
            return source
        case "readerExtract":
            guard let url = request.url, let source = readerSources[url] else {
                throw Failure(message: "Reopen this page to use Reader.")
            }
            var result = await ReaderCapture.extract(source, preview: model.readerPreview)
            result.removeValue(forKey: "readerTarget")
            return result
        case "notesStatus": return model.notes.status()
        case "notesChooseVault": return try model.notes.chooseVault()
        case "notesChooseFolder": return try model.notes.chooseFolder()
        case "noteLoad":
            guard let url = request.url, url.count <= 16_384 else { throw Failure(message: "Choose a valid page first.") }
            var result = try model.notes.load(url: url, title: String((request.title ?? "Untitled page").prefix(10_000)))
            result["quickNote"] = model.library.links.first(where: { Library.identity($0.url) == Library.identity(url) })?.note ?? ""
            return result
        case "noteSave", "noteDraft", "noteCheck", "noteSaveCopy", "noteOpen", "noteReveal", "noteLocate", "noteDiscardDraft":
            guard let id = request.documentId, UUID(uuidString: id) != nil else { throw Failure(message: "Reopen this note and try again.") }
            if let text = request.text, text.count > NoteFiles.maximumCharacters { throw Failure(message: "This note reached the editor size limit.") }
            switch request.command {
            case "noteSave", "noteDraft":
                guard let text = request.text, let revision = request.revision, revision.count <= 100 else { throw Failure(message: "The note save request was incomplete.") }
                if request.command == "noteSave" { return try model.notes.save(id: id, text: text, revision: revision) }
                try model.notes.draft(id: id, text: text, revision: revision); return ["saved": true]
            case "noteCheck": return try model.notes.check(id: id, revision: request.revision ?? "")
            case "noteSaveCopy":
                guard let text = request.text else { throw Failure(message: "There is no text to save.") }
                return try model.notes.saveCopy(id: id, text: text)
            case "noteOpen": try model.notes.open(id: id); return ["opened": true]
            case "noteReveal": try model.notes.reveal(id: id); return ["opened": true]
            case "noteLocate": return try model.notes.locate(id: id)
            default: try model.notes.discardDraft(id: id); return ["discarded": true]
            }
        default: return nil
        }
    }

    private func perform(_ request: Request) async throws {
        let search = model.tabSearch
        let ids = Set(request.ids ?? [])
        let items = search.results.filter { ids.contains($0.id) }
        let tabs = items.compactMap(\.tab)
        let links = Array(Dictionary(items.compactMap(\.link).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        switch request.command {
        case "panelWillShow":
            panelVisible = true
            if let front = NSWorkspace.shared.frontmostApplication,
               !["app.savenest.mac", "app.savenest.electron", "org.electronjs.Electron"].contains(front.bundleIdentifier ?? "") { previousApplication = front }
        case "restoreFocus": previousApplication?.activate(options: [])
        case "snapshot": snapshot()
        case "loginItemStatus":
            guard let enabled = request.enabled, let available = request.available else { throw Failure(message: "Invalid startup status.") }
            model.launchAtLogin.receive(enabled: enabled, available: available, message: request.message ?? "")
        case "updateStatus":
            guard let enabled = request.enabled, let state = request.updateState,
                  model.updater.receiveHostStatus(enabled: enabled, state: state) else {
                throw Failure(message: "Invalid update status.")
            }
        case "checkForUpdates": model.updater.checkForUpdates()
        case "search":
            if let scope = request.scope, let value = TabScope(rawValue: scope) { search.scope = value }
            if let query = request.query { search.query = String(query.prefix(2_000)) }
        case "resume": search.refresh()
        case "refresh", "browserAccess":
            guard model.isPreview || BrowserAccess.confirm() else { return }
            search.refresh(); search.refreshHistory(force: true)
        case "historyEnabled":
            if request.enabled == true && !model.isPreview && !BrowserAccess.confirm() { return }
            search.historyEnabled = request.enabled ?? false
        case "historyAccess":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        case "suspend": panelVisible = false; search.suspend()
        case "retryContext": search.retryContext()
        case "open":
            guard let item = items.first else { throw Failure(message: "This item changed. Refresh and try again.") }
            if let tab = item.tab { search.activate(tab) }
            else {
                if model.isPreview { search.setMessage("Preview: this would open the saved link.") }
                else { model.open(item.link ?? SavedLink(url: item.url, title: item.title)); event("hide") }
            }
        case "copy":
            guard !items.isEmpty else { throw Failure(message: "Select a link first.") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.map(\.url).joined(separator: "\n"), forType: .string)
            search.setMessage("Copied \(items.count) \(items.count == 1 ? "link" : "links").")
        case "save", "saveClose":
            for item in items where item.tab == nil && item.link == nil {
                guard await model.add(url: item.url, title: item.title, collection: "Inbox") else {
                    throw Failure(message: "Couldn’t save. Check your library and try again.")
                }
                search.setMessage("Saved to your library.")
            }
            search.saveTabs(tabs, closeAfter: request.command == "saveClose")
        case "close": search.closeTabs(tabs)
        case "activityOpen":
            guard let requested = request.ids, requested.count == 1,
                  let id = UUID(uuidString: requested[0]),
                  let link = model.library.links.first(where: { $0.id == id }),
                  Library.validatedURL(link.url) != nil else {
                throw Failure(message: "This saved link is no longer available. Refresh Activity and try again.")
            }
            if model.isPreview { search.setMessage("Preview: this would open the saved link.") }
            else if let tab = search.tabs.first(where: { Library.identity($0.url) == Library.identity(link.url) }) {
                search.activate(tab)
            } else { model.open(link); event("hide") }
        case "favorite": model.toggleFavorites(ids: Set(links.map(\.id)))
        case "archive", "restore": _ = model.setArchived(request.command == "archive", ids: Set(links.map(\.id)))
        case "delete": model.deleteLinks(ids: Set(links.map(\.id)))
        case "undo": model.undoLastAction()
        case "edit":
            guard let item = items.first else { throw Failure(message: "This item changed. Reopen the editor.") }
            guard let revision = request.revision else { throw Failure(message: "Reopen the editor before saving this link.") }
            var link = item.link ?? SavedLink(url: item.url, title: item.title, browser: item.tab?.browserName ?? "Manual")
            link.title = request.title ?? link.title; link.note = request.note ?? link.note
            link.tags = request.tags ?? link.tags
            guard await model.saveWorkspaceLink(link, expectedRevision: revision) else { throw Failure(message: model.error ?? "Couldn’t save. Check your library and try again.") }
        case "add":
            guard await model.add(url: request.url ?? "", title: request.title ?? "", collection: "Inbox", note: request.note ?? "", tags: request.tags ?? []) else {
                throw Failure(message: model.error ?? "Couldn’t save. Check your library and try again.")
            }
        case "saveDraft":
            guard var draft = model.draft, request.ids == [draft.id.uuidString] else { throw Failure(message: "This capture changed. Try saving the tab again.") }
            draft.link.title = request.title ?? draft.link.title; draft.link.note = request.note ?? draft.link.note; draft.link.tags = request.tags ?? draft.link.tags
            guard await model.saveDraft(draft.link) else { throw Failure(message: model.error ?? "Couldn’t save. Check your library and try again.") }
        case "cancelDraft": model.cancelDraft()
        case "saveSelection":
            guard let draft = model.tabSelection else { return }
            let selected = Set(draft.links.filter { ids.contains($0.id.uuidString) }.map(\.id))
            guard !selected.isEmpty else { throw Failure(message: "Select at least one tab.") }
            guard model.canWriteLibrary else { throw Failure(message: "Your library could not be opened. Restore a valid backup before saving.") }
            model.updateTabSelection(selected)
            guard model.saveTabSelection() else { throw Failure(message: "Couldn’t save these tabs. Your selection is still here; try again.") }
        case "cancelSelection": model.cancelTabSelection()
        case "saveClipboard": if !model.isPreview { model.saveCurrentClipboard() }
        case "account": model.showAccount?()
        case "settings": model.showSettings?()
        case "requestFeature", "reportBug":
            guard let destination = FeedbackDestination(rawValue: request.command), NSWorkspace.shared.open(destination.url) else {
                throw Failure(message: "Couldn’t open GitHub. Check your default browser and try again.")
            }
        case "socialCaptureSettings":
            model.requestedSettingsTab = "Capture"
            model.showSettings?()
        case "tags": model.showSettings?(); model.showingTags = true
        case "share":
            guard let link = links.first else { return }
            model.showSettings?(); model.share(link)
        case "cleanup": model.showSettings?(); model.runTabCleanup()
        case "export": NSApp.activate(ignoringOtherApps: true); model.exportLibrary()
        case "import": NSApp.activate(ignoringOtherApps: true); model.importLibrary()
        case "capture":
            guard let action = CaptureAction(rawValue: request.action ?? "quick") else { return }
            if model.isPreview {
                guard let tab = search.tabs.first else { return }
                let link = SavedLink(url: tab.url, title: tab.title, browser: tab.browserName)
                if action == .note { model.beginDraft(link, action: .note) }
                else if action == .selected {
                    model.tabSelection = TabSelectionDraft(links: search.tabs.map { SavedLink(url: $0.url, title: $0.title, browser: $0.browserName) })
                } else if action == .window { search.saveTabs(search.tabs) }
                else if action == .quick { search.saveTabs([tab]) }
                return
            }
            model.capture(action: action, sourceApplication: panelVisible ? previousApplication : nil)
        case "serviceCapture":
            guard let raw = request.url, let url = ClipboardLink.parse(raw) else {
                throw Failure(message: "Select one complete http:// or https:// web address.")
            }
            if let message = model.beginServicesCapture(url) { throw Failure(message: message) }
        case "callback":
            guard !model.isPreview, let raw = request.url, let url = URL(string: raw), url.scheme == "savenest" else { return }
            model.account.handleIncomingURL(url)
        case "synchronize": if !model.isPreview { await model.account.synchronizeLogin() }
        case "privacy": NSWorkspace.shared.open(URL(string: "https://savenest.app/privacy")!)
        case "usageNoticeDismiss": model.dismissUsageNotice()
        case "analyticsEnabled":
            guard let enabled = request.enabled else { return }
            model.analyticsEnabled = enabled
            if !enabled { model.dismissUsageNotice() }
        case "onboardingDone": model.completeOnboarding()
        case "onboardingStart": model.showOnboarding()
        case "dismissMessage": model.error = nil; search.setMessage("")
        default: throw Failure(message: "Unknown Savenest action.")
        }
    }
}

/// Preserve secondary native tools while the workspace is hosted by Electron.
struct ElectronUtilitySheets: ViewModifier {
    @ObservedObject var model: AppModel
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .sheet(isPresented: $model.showingTags) { TagsView(model: model, onBack: { model.showingTags = false }) }
                .sheet(item: $model.sharingLink) { EmailShareView(link: $0) }
                .sheet(item: $model.cleanupReview) { TabCleanupReviewView(model: model, draftID: $0.id) }
        } else { content }
    }
}
