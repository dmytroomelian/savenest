import AppKit
import CryptoKit
import SaveNestCore

struct AutomationTab {
    let tab: OpenBrowserTab
    let processID: pid_t
    let launchedAt: Date?
    let reference: String
    let processBirth: AutomationProcessBirth?

    init(tab: OpenBrowserTab, processID: pid_t, launchedAt: Date?, reference: String, processBirth: AutomationProcessBirth? = nil) {
        self.tab = tab; self.processID = processID; self.launchedAt = launchedAt
        self.reference = reference; self.processBirth = processBirth
    }
}

enum AutomationTabReference {
    static func make(tab: OpenBrowserTab, birth: AutomationProcessBirth, session: String, safari: Bool) -> String {
        // Chromium identifies a tab independently of its position. Safari exposes only an index.
        let position = safari || tab.tabID.isEmpty ? "index:\(tab.index)" : "tab:\(tab.tabID)"
        let fields = [session, birth.referenceComponent, tab.browserID, tab.windowID, position, tab.url]
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol AutomationBrowsing {
    func snapshot() async throws -> (tabs: [AutomationTab], warnings: [String])
    func close(_ tab: AutomationTab) async throws -> Bool
    func activate(_ tab: AutomationTab) async throws -> Bool
    func open(_ url: URL) -> Bool
    func history() async throws -> (entries: [BrowserHistoryEntry], warnings: [String])
}

@MainActor
final class AutomationBrowser: AutomationBrowsing {
    private let session = UUID().uuidString
    #if DEBUG
    var snapshotObserverForTesting: (([AutomationTab], [String]) -> Void)?
    #endif
    func snapshot() async throws -> (tabs: [AutomationTab], warnings: [String]) {
        var tabs: [AutomationTab] = [], warnings: [String] = []
        for browser in Browser.supported {
            try Task.checkCancellation()
            let processes = runningApplications(browser.id)
            guard processes.count <= 1 else { warnings.append("Quit duplicate copies of \(browser.name) before using its tabs."); continue }
            guard let process = processes.first else { continue }
            let pid = process.processIdentifier, launchedAt = process.launchDate
            guard let processBirth = AutomationProcessBirth.read(pid) else {
                warnings.append("\(browser.name) could not be read. Its process could not be verified. Refresh and try again.")
                continue
            }
            do {
                let script = BrowserTabScript.script + "\nfunction run() { return JSON.stringify(readBrowserTabs(Application('\(browser.id)'), {id:'\(browser.id)',name:'\(browser.name)',safari:\(browser.safari)})); }"
                let data = try await BrowserScript.run(script, timeout: 8)
                let current = runningApplications(browser.id)
                guard current.count == 1, current.first?.processIdentifier == pid,
                      AutomationProcessBirth.matches(processBirth, processID: pid) else {
                    warnings.append("\(browser.name) could not be read. Its process changed during the request. Refresh and try again.")
                    continue
                }
                let found = try JSONDecoder().decode([OpenBrowserTab].self, from: data)
                for tab in found where Library.validatedURL(tab.url) != nil {
                    let reference = AutomationTabReference.make(tab: tab, birth: processBirth, session: session, safari: browser.safari)
                    tabs.append(AutomationTab(tab: tab, processID: pid, launchedAt: launchedAt, reference: reference, processBirth: processBirth))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("\(browser.name) could not be read. Check macOS Automation permission.") }
        }
        #if DEBUG
        snapshotObserverForTesting?(tabs, warnings)
        #endif
        return (tabs, warnings)
    }
    private func runningApplications(_ browserID: String) -> [NSRunningApplication] {
        // Static NSRunningApplication lookups can transiently return no process while the workspace still knows it.
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleIdentifier == browserID }
    }
    private func requireProcess(_ target: AutomationTab) throws -> Browser {
        let applications = runningApplications(target.tab.browserID)
        guard let browser = Browser.supported.first(where: { $0.id == target.tab.browserID }),
              applications.count == 1, let app = applications.first,
              app.processIdentifier == target.processID, app.bundleIdentifier == browser.id,
              AutomationProcessBirth.matches(target.processBirth, processID: target.processID) else {
            throw AutomationFailure(code: "stale_tab", message: "The browser restarted or the tab is no longer available. Search again.")
        }
        return browser
    }
    func close(_ target: AutomationTab) async throws -> Bool {
        try Task.checkCancellation()
        let browser = try requireProcess(target)
        struct Target: Encodable { let windowID: String; let tabID: String; let index: Int; let url: String; let safari: Bool }
        let tab = target.tab
        let value = Target(windowID: tab.windowID, tabID: tab.tabID, index: tab.index - 1, url: tab.url, safari: browser.safari)
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let script = TabCloseScript.script + """
        \nfunction run() {
            const app = Application('\(browser.id)'), target = \(json);
            if (!closeCapturedTab(app, target)) return 'false';
            const wi = app.windows.id().map(String).indexOf(target.windowID);
            if (wi < 0) return 'true';
            const w = app.windows[wi];
            return String(target.safari ? w.tabs.url().indexOf(target.url) < 0 : w.tabs.id().map(String).indexOf(target.tabID) < 0);
        }
        """
        let data = try await BrowserScript.run(script, timeout: 8)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
    func activate(_ target: AutomationTab) async throws -> Bool {
        try Task.checkCancellation()
        let browser = try requireProcess(target), tab = target.tab
        let value: [String: AutomationValue] = ["windowID": .string(tab.windowID), "tabID": .string(tab.tabID),
            "index": .number(Double(tab.index)), "url": .string(tab.url), "safari": .bool(browser.safari)]
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let script = BrowserTabScript.script + "\nfunction run() { return String(activateBrowserTab(Application('\(browser.id)'), \(json))); }"
        return String(decoding: try await BrowserScript.run(script, timeout: 8), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    func history() async throws -> (entries: [BrowserHistoryEntry], warnings: [String]) {
        let task = Task.detached(priority: .utility) { HistoryDiscovery.scan() }
        let scan = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return (scan.entries, scan.statuses.compactMap { $0.issue == nil ? nil : "\($0.source.browser) history could not be read. Check macOS Privacy & Security." })
    }
}
