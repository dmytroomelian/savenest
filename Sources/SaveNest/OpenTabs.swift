import AppKit
import SwiftUI
import SaveNestCore

enum BrowserScript {
    static func run(_ script: String, timeout seconds: Double = 15) async throws -> Data {
        let job = ScriptProcess()
        return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", "-e", script]
                process.standardOutput = output; process.standardError = errors
                do {
                    try job.start(process)
                    let errorBox = ScriptErrorOutput(), drain = DispatchGroup()
                    drain.enter()
                    DispatchQueue.global().async { errorBox.data = errors.fileHandleForReading.readDataToEndOfFile(); drain.leave() }
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); timeout.cancel(); drain.wait()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorBox.data, encoding: .utf8) ?? ""
                        throw CaptureError.failed(message.contains("1743") ? "Allow Savenest in System Settings → Privacy & Security → Automation." : "The browser did not respond. Try refreshing.")
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
        }, onCancel: { job.cancel() })
    }
}
private final class ScriptErrorOutput: @unchecked Sendable { var data = Data() }

private final class ScriptProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); self.process = process
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

@MainActor
final class TabSearchModel: ObservableObject {
    @Published var query = "" { didSet { search(resetSelection: true) } }
    @Published var scope = TabScope.all { didSet { markedIDs = []; search(resetSelection: true) } }
    @Published private(set) var tabs: [OpenBrowserTab] = []
    @Published private(set) var results: [TabWorkspaceItem] = []
    @Published private(set) var resultsQuery = ""
    @Published private(set) var resultsScope = TabScope.all
    @Published private(set) var loading = false
    @Published private(set) var loadingContext = false
    @Published private(set) var switching = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var contextUnavailable = false
    @Published private(set) var history: [BrowserHistoryEntry] = []
    @Published private(set) var historySources: [HistorySourceStatus] = []
    @Published private(set) var loadingHistory = false
    @Published var historyEnabled = UserDefaults.standard.object(forKey: "historySearchEnabled") as? Bool ?? true {
        didSet {
            if !isPreview { UserDefaults.standard.set(historyEnabled, forKey: "historySearchEnabled") }
            if historyEnabled { refreshHistory(force: true) }
            else {
                historyGeneration = UUID(); historyTask?.cancel(); historyReadTask?.cancel(); searchTask?.cancel()
                history = []; historySources = []; results = []; loadingHistory = false; rebuildIndex()
            }
        }
    }
    @Published var selectedIndex = 0
    @Published var markedIDs: Set<String> = []
    var close: (() -> Void)?
    var save: (([OpenBrowserTab]) async -> Bool)?
    private var links: [SavedLink] = []
    private var cache = TabContextCache()
    private var index = TabWorkspaceIndex()
    private var indexIncludesHistory = false
    private var refreshTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var indexGeneration = UUID()
    private var historyGeneration = UUID()
    private var historyTask: Task<Void, Never>?
    private var historyReadTask: Task<HistoryDiscovery.Scan, Never>?
    private var historyReadAt: Date?
    private var previewHistory: [BrowserHistoryEntry] = []
    private var generation = UUID()
    private var blockedUntil: [String: Date] = [:]
    private var isPreview = false
    var selected: TabWorkspaceItem? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }
    var selectedItems: [TabWorkspaceItem] { markedIDs.isEmpty ? selected.map { [$0] } ?? [] : results.filter { markedIDs.contains($0.id) } }

    func updateLibrary(_ links: [SavedLink]) { self.links = links; rebuildIndex() }
    func move(_ offset: Int) { selectedIndex = max(0, min(results.count - 1, selectedIndex + offset)) }
    func toggleSelection(_ item: TabWorkspaceItem) {
        if markedIDs.contains(item.id) { markedIDs.remove(item.id) } else { markedIDs.insert(item.id) }
    }
    func setMessage(_ text: String) { message = text }
    func setPreview(tabs: [OpenBrowserTab], contexts: [String: String], history: [BrowserHistoryEntry] = []) {
        isPreview = true; self.tabs = tabs
        self.previewHistory = history; self.history = history; historyEnabled = true
        for tab in tabs { cache.store(contexts[tab.contextKey] ?? "", for: tab) }
        rebuildIndex()
    }
    func suspend() {
        generation = UUID(); refreshTask?.cancel(); contextTask?.cancel()
        loading = false; loadingContext = false
    }
    func refresh() {
        guard !isPreview else { rebuildIndex(); return }
        refreshHistory()
        suspend()
        let current = generation
        loading = true; message = nil; contextUnavailable = false
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let browsers = Browser.supported.filter { running.contains($0.id) }
        // Keep cached rows until each browser answers. One slow browser cannot block the others.
        tabs.removeAll { !running.contains($0.browserID) }
        rebuildIndex()
        refreshTask = Task {
            var failures: [String] = []
            await withTaskGroup(of: (String, [OpenBrowserTab]?).self) { group in
                for browser in browsers {
                    group.addTask {
                        let script = """
                        \(BrowserTabScript.script)
                        function run() {
                            return JSON.stringify(readBrowserTabs(Application('\(browser.id)'), {id:'\(browser.id)', name:'\(browser.name)', safari:\(browser.safari)}));
                        }
                        """
                        do {
                            let data = try await BrowserScript.run(script)
                            return (browser.id, try JSONDecoder().decode([OpenBrowserTab].self, from: data))
                        } catch { return (browser.id, nil) }
                    }
                }
                for await (browserID, found) in group {
                    guard generation == current, !Task.isCancelled else { group.cancelAll(); return }
                    if let found {
                        tabs.removeAll { $0.browserID == browserID }; tabs += found.filter { Library.validatedURL($0.url) != nil }
                        tabs.sort { $0.browserID == $1.browserID ? ($0.windowID == $1.windowID ? $0.index < $1.index : $0.windowID < $1.windowID) : $0.browserID < $1.browserID }
                        rebuildIndex()
                    } else { failures.append(Browser.supported.first { $0.id == browserID }?.name ?? browserID) }
                }
            }
            guard generation == current, !Task.isCancelled else { return }
            loading = false
            cache.prune(tabs: tabs)
            if !failures.isEmpty { message = "Couldn’t refresh \(failures.joined(separator: ", ")). Check Automation access. Previous results remain available." }
            loadContext(generation: current, excluding: Set(browsers.filter { failures.contains($0.name) }.map(\.id)))
        }
    }
    func refreshHistory(force: Bool = false) {
        if isPreview { if historyEnabled { history = previewHistory; rebuildIndex() }; return }
        guard historyEnabled, !isPreview, !loadingHistory,
              force || historyReadAt == nil || Date().timeIntervalSince(historyReadAt!) > 60 else { return }
        let current = UUID(); historyGeneration = current; loadingHistory = true
        let read = Task.detached(priority: .utility) { HistoryDiscovery.scan() }
        historyReadTask = read
        historyTask = Task {
            let scan = await read.value
            guard historyGeneration == current, historyEnabled, !Task.isCancelled else { return }
            history = scan.entries; historySources = scan.statuses; loadingHistory = false; historyReadAt = Date()
            rebuildIndex()
        }
    }
    private func rebuildIndex() {
        indexTask?.cancel()
        let current = UUID(); indexGeneration = current
        let tabs = tabs, links = links, history = history, previous = index
        let contexts = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in cache.text(for: tab).map { (tab.contextKey, $0) } })
        indexTask = Task {
            let next = await Task.detached(priority: .userInitiated) { TabWorkspaceIndex(tabs: tabs, links: links, contexts: contexts, history: history, reusing: previous) }.value
            guard indexGeneration == current, !Task.isCancelled else { return }
            index = next; indexIncludesHistory = !history.isEmpty; search(resetSelection: false)
        }
    }
    private func search(resetSelection: Bool) {
        searchTask?.cancel()
        let query = query, scope = scope, index = index, includesHistory = indexIncludesHistory
        let selectedID = resetSelection ? nil : selected?.id
        searchTask = Task {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(40)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { index.search(query, scope: scope) }.value
            guard !Task.isCancelled else { return }
            // A pause clears results immediately; wait for the clean index before searching again.
            guard historyEnabled || !includesHistory else { return }
            results = found
            resultsQuery = query; resultsScope = scope
            markedIDs.formIntersection(Set(found.map(\.id)))
            selectedIndex = selectedID.flatMap { id in found.firstIndex { $0.id == id } } ?? 0
        }
    }
    private struct ContextTarget: Encodable {
        let key: String; let windowID: String; let tabID: String; let index: Int; let url: String
    }
    private struct ContextResponse: Decodable {
        struct Value: Decodable { let key: String; let text: String }
        let contexts: [Value]; let blocked: Bool
    }
    private func loadContext(generation current: UUID, excluding: Set<String>) {
        contextTask = Task {
            loadingContext = true
            defer { if generation == current { loadingContext = false } }
            let groups = Dictionary(grouping: tabs.filter { cache.text(for: $0) == nil && !excluding.contains($0.browserID) }, by: \.browserID)
            for (browserID, pending) in groups {
                guard generation == current, !Task.isCancelled else { return }
                if let until = blockedUntil[browserID], until > Date() { contextUnavailable = true; continue }
                guard let browser = Browser.supported.first(where: { $0.id == browserID }) else { continue }
                for offset in stride(from: 0, to: pending.count, by: 4) {
                    guard generation == current, !Task.isCancelled else { return }
                    let batch = Array(pending[offset..<min(offset + 4, pending.count)])
                    let targets = batch.map { ContextTarget(key: $0.contextKey, windowID: $0.windowID, tabID: $0.tabID, index: $0.index, url: $0.url) }
                    do {
                        let payload = String(data: try JSONEncoder().encode(targets), encoding: .utf8)!
                        let source = String(data: try JSONEncoder().encode(TabContextScript.page), encoding: .utf8)!
                        let script = TabContextScript.reader + "\nfunction run() { return JSON.stringify(readTabContexts(Application('\(browser.id)'), \(payload), \(browser.safari), \(source))); }"
                        let data = try await BrowserScript.run(script, timeout: 3)
                        guard generation == current, !Task.isCancelled else { return }
                        let response = try JSONDecoder().decode(ContextResponse.self, from: data)
                        for value in response.contexts {
                            if let tab = batch.first(where: { $0.contextKey == value.key }) { cache.store(value.text, for: tab) }
                        }
                        rebuildIndex()
                        if response.blocked { blockedUntil[browserID] = Date().addingTimeInterval(300); contextUnavailable = true; break }
                        for tab in batch where cache.text(for: tab) == nil { cache.store("", for: tab) }
                    } catch {
                        guard generation == current else { return }
                        blockedUntil[browserID] = Date().addingTimeInterval(300); contextUnavailable = true; break
                    }
                }
            }
        }
    }
    func retryContext() { blockedUntil = [:]; refresh() }
    func saveTabs(_ tabs: [OpenBrowserTab], closeAfter: Bool = false) {
        guard !busy, !tabs.isEmpty, let save else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await save(tabs) else { message = "Couldn’t save. Check your account or the Savenest notification."; return }
            if closeAfter { await closeTabsNow(tabs) }
            else { message = tabs.count == 1 ? "Saved to your library." : "Saved \(tabs.count) tabs." }
        }
    }
    func closeTabs(_ tabs: [OpenBrowserTab]) {
        guard !busy, !tabs.isEmpty else { return }
        busy = true
        Task { defer { busy = false }; await closeTabsNow(tabs) }
    }
    private func closeTabsNow(_ targets: [OpenBrowserTab]) async {
        if isPreview {
            let ids = Set(targets.map(\.id)); tabs.removeAll { ids.contains($0.id) }; rebuildIndex(); return
        }
        var closed = 0
        // Use the strict single-tab guard: ambiguous Safari duplicates stay open.
        for tab in targets.sorted(by: { $0.index > $1.index }) {
            guard let browser = Browser.supported.first(where: { $0.id == tab.browserID }) else { continue }
            struct Target: Encodable { let windowID: String; let tabID: String; let index: Int; let url: String; let safari: Bool }
            let target = Target(windowID: tab.windowID, tabID: tab.tabID, index: tab.index - 1, url: tab.url, safari: browser.safari)
            do {
                let json = String(data: try JSONEncoder().encode(target), encoding: .utf8)!
                let data = try await BrowserScript.run(TabCloseScript.script + "\nfunction run() { return String(closeCapturedTab(Application('\(browser.id)'), \(json))); }")
                if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                    closed += 1; tabs.removeAll { $0.id == tab.id }
                }
            } catch { /* Keep the row until refresh confirms the current browser state. */ }
        }
        rebuildIndex(); refresh()
        message = closed == targets.count ? "Closed \(closed) \(closed == 1 ? "tab" : "tabs")." : "Closed \(closed) of \(targets.count). Changed, ambiguous, or unavailable tabs stayed open."
    }
    func activate(_ tab: OpenBrowserTab) {
        if isPreview { message = "Preview: this would switch to the selected browser tab."; return }
        guard !switching, let browser = Browser.supported.first(where: { $0.id == tab.browserID }) else { return }
        switching = true
        // Encode page data as JSON literals; never interpolate a title or URL as executable code.
        let url = String(data: try! JSONEncoder().encode(tab.url), encoding: .utf8)!
        let windowID = String(data: try! JSONEncoder().encode(tab.windowID), encoding: .utf8)!
        let tabID = String(data: try! JSONEncoder().encode(tab.tabID), encoding: .utf8)!
        Task {
            defer { switching = false }
            do {
                let script = """
                \(BrowserTabScript.script)
                function run() {
                    return String(activateBrowserTab(Application('\(browser.id)'), {
                        windowID:\(windowID), tabID:\(tabID), index:\(tab.index), url:\(url), safari:\(browser.safari)
                    }));
                }
                """
                let data = try await BrowserScript.run(script)
                guard String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                    message = "That tab moved or closed. Refresh to see what’s open now."; return
                }
                close?()
            } catch { message = "Couldn’t switch tabs. Check browser Automation access and try again." }
        }
    }
}
