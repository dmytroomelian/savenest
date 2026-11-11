import AppKit
import CoreGraphics
import SaveNestCore

struct Browser {
    let id: String
    let name: String
    var safari: Bool { id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" }
    static let supported: [Browser] = [
        .init(id: "com.apple.Safari", name: "Safari"),
        .init(id: "com.apple.SafariTechnologyPreview", name: "Safari Preview"),
        .init(id: "com.google.Chrome", name: "Chrome"),
        .init(id: "com.google.Chrome.beta", name: "Chrome Beta"),
        .init(id: "com.brave.Browser", name: "Brave"),
        .init(id: "com.microsoft.edgemac", name: "Edge"),
        .init(id: "company.thebrowser.Browser", name: "Arc"),
        .init(id: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        .init(id: "org.chromium.Chromium", name: "Chromium"),
        .init(id: "com.operasoftware.Opera", name: "Opera")
    ]
}

enum CaptureError: LocalizedError {
    case noBrowser, unsupported(String), permission(String), failed(String), noTabs
    var notice: CaptureNotice {
        switch self {
        case .noBrowser:
            return CaptureNotice(title: "No browser found", message: "Open a page in Safari or Chrome, then try your shortcut again.", isError: true)
        case .noTabs:
            return CaptureNotice(title: "No tabs to save", message: "Open a web page first. Empty tabs and browser settings can’t be saved.", isError: true)
        case .permission(let name):
            return CaptureNotice(title: "Browser access needed", message: "Allow Savenest to read tabs from \(name) in macOS Automation settings.", isError: true, opensAutomationSettings: true)
        case .unsupported(let name):
            return CaptureNotice(title: "\(name) isn’t supported yet", message: "Copy the page address and use Add link → Paste URL, or open it in Safari or Chrome.", isError: true)
        case .failed:
            return CaptureNotice(title: "Couldn’t capture this tab", message: "Check that your browser has a web page open, then try again.", isError: true)
        }
    }
    var errorDescription: String? {
        switch self {
        case .noBrowser: return "No browser tab found. Open a page in Safari or Chrome, then press your shortcut again. Savenest will remember that browser for captures from other apps."
        case .unsupported(let name): return "Direct tab capture isn’t available for \(name) yet. Copy the page address and use Add link → Paste URL, or open it in Safari or Chrome."
        case .permission(let name): return "Allow Savenest to read tabs from \(name) in System Settings → Privacy & Security → Automation, then try again."
        case .failed(let reason): return "Couldn’t read this browser window. \(reason)"
        case .noTabs: return "There are no web pages to save in this window. New tabs, browser settings, and local files are skipped."
        }
    }
}

struct CapturedTabs {
    let links: [SavedLink]
    let closeTarget: CapturedTabTarget?
}

final class BrowserCapture {
    private var observation: NSObjectProtocol?
    private var lastBrowserID: String?
    init() {
        lastBrowserID = UserDefaults.standard.string(forKey: "lastCaptureBrowser")
        remember(NSWorkspace.shared.frontmostApplication)
        observation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            self?.remember(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }
    deinit { if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) } }
    private func remember(_ app: NSRunningApplication?) {
        if let id = app?.bundleIdentifier, Browser.supported.contains(where: { $0.id == id }) {
            lastBrowserID = id
            UserDefaults.standard.set(id, forKey: "lastCaptureBrowser")
        }
    }
    func target(sourceApplication: NSRunningApplication? = nil) throws -> Browser {
        let front = sourceApplication ?? NSWorkspace.shared.frontmostApplication
        let supported = Set(Browser.supported.map(\.id))
        // Do not silently capture Chrome while the user is trying to save a Firefox/other browser tab.
        if let id = front?.bundleIdentifier, !supported.contains(id), id != Bundle.main.bundleIdentifier {
            // URL handlers also include ordinary apps (such as ChatGPT); they aren't all browsers.
            let unsupportedBrowserPrefixes = [
                "org.mozilla.firefox",
                "app.zen-browser",
                "com.kagi.kagimacOS",
                // Codex's in-app browser is rendered inside the Codex process and does not
                // expose Safari/Chromium tab scripting. Treat it as a browser here so a
                // capture attempt explains what happened instead of falling back to a
                // previously used browser.
                "com.openai.codex"
            ]
            if unsupportedBrowserPrefixes.contains(where: { id.hasPrefix($0) }) {
                throw CaptureError.unsupported(front?.localizedName ?? "this browser")
            }
        }
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let id: String?
        if let first = BrowserTarget.resolve(front: front?.bundleIdentifier, supported: supported, running: runningIDs, remembered: lastBrowserID, visible: []) {
            id = first
        } else {
            // Cold start: use the nearest visible browser. Only owner PID/layer metadata is read;
            // no screen contents, window titles, Screen Recording or Accessibility access is used.
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let visible = windows.compactMap { window -> String? in
                guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return nil }
                return running.first { $0.processIdentifier == pid }?.bundleIdentifier
            }
            id = BrowserTarget.resolve(front: front?.bundleIdentifier, supported: supported, running: runningIDs, remembered: lastBrowserID, visible: visible)
        }
        guard let browser = Browser.supported.first(where: { $0.id == id }) else { throw CaptureError.noBrowser }
        lastBrowserID = browser.id
        UserDefaults.standard.set(browser.id, forKey: "lastCaptureBrowser")
        return browser
    }
    func closeSavedTab(_ target: CapturedTabTarget) async -> Bool {
        guard Browser.supported.contains(where: { $0.id == target.browserID }),
              NSRunningApplication.runningApplications(withBundleIdentifier: target.browserID).contains(where: { $0.processIdentifier == target.processID }) else { return false }
        do {
            let payload = String(data: try JSONEncoder().encode(target), encoding: .utf8)!
            let data = try await BrowserScript.run(TabCloseScript.script + "\nfunction run() { return String(closeCapturedTab(Application('" + target.browserID + "'), " + payload + ")); }")
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch { return false }
    }
    func capture(allTabs: Bool, prepareClose: Bool = false, sourceApplication: NSRunningApplication? = nil, completion: @escaping (Result<CapturedTabs, Error>) -> Void) {
        let browser: Browser
        do { browser = try target(sourceApplication: sourceApplication) }
        catch { completion(.failure(error)); return }
        let processID = NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).first?.processIdentifier ?? 0
        // Browser IDs come only from the allowlist. No page content is evaluated as code.
        let tabExpression = allTabs ? "w.tabs()" : (browser.safari ? "[w.currentTab()]" : "[w.activeTab()]")
        let encodedReader = String(data: try! JSONEncoder().encode(PageMetadata.script), encoding: .utf8)!
        let script = """
        \(TabCloseScript.script)
        function run() {
            const app = Application('\(browser.id)');
            if (!app.running() || app.windows.length === 0) return '[]';
            const w = app.windows[0];
            const reader = \(encodedReader);
            const result = \(tabExpression).map(function(tab) {
                try {
                    const result = {url: tab.url() || '', title: tab.\(browser.safari ? "name" : "title")() || '', metadata: {}};
                    if (!/^https?:/i.test(result.url)) return result;
                    if (\(prepareClose ? "true" : "false")) {
                        try {
                            const index = \(browser.safari ? "uniqueSafariTabIndex(w, result.url)" : "-1");
                            if (!\(browser.safari ? "true" : "false") || index >= 0) {
                                result.closeTarget = {windowID:String(w.id()), index:index, tabID:\(browser.safari ? "null" : "String(tab.id())"), url:result.url, safari:\(browser.safari ? "true" : "false"), browserID:'\(browser.id)', processID:\(processID)};
                            }
                        } catch (_) { /* Save still works when stable tab identity is unavailable. */ }
                    }
                    try {
                        const raw = \(browser.safari ? "app.doJavaScript(reader, {in: tab})" : "tab.execute({javascript: reader})");
                        const metadata = JSON.parse(raw);
                        // A navigation during capture must not attach another page's title.
                        if (metadata.url === result.url) result.metadata = metadata;
                    } catch (_) { /* Browser JavaScript permission is optional; retain the native title. */ }
                    return result;
                } catch (_) { return null; }
            }).filter(Boolean);
            return JSON.stringify(result);
        }
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            process.standardOutput = output; process.standardError = errors
            do {
                try process.run()
                // Drain both pipes concurrently, including large windows; never block the app UI.
                let errorBox = CaptureOutput()
                let group = DispatchGroup(); group.enter()
                DispatchQueue.global().async {
                    errorBox.data = errors.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); group.wait()
                let errorText = String(data: errorBox.data, encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    if errorText.contains("1743") || errorText.localizedCaseInsensitiveContains("not authorized") { throw CaptureError.permission(browser.name) }
                    throw CaptureError.failed("Check that the browser has an open window and try again.")
                }
                struct Tab: Decodable { let url: String; let title: String; let metadata: [String: String]?; let closeTarget: CapturedTabTarget? }
                let tabs = try JSONDecoder().decode([Tab].self, from: data)
                let links = tabs.filter { Library.validatedURL($0.url) != nil }.map { tab in
                    var link = SavedLink(url: tab.url, title: LinkTitle.best(url: tab.url, browserTitle: tab.title, metadata: tab.metadata ?? [:]), browser: browser.name)
                    link.iconURL = SiteIcon.resolve(tab.metadata?["iconURL"], relativeTo: URL(string: tab.url)!)?.absoluteString
                    return link
                }
                guard !links.isEmpty else { throw CaptureError.noTabs }
                DispatchQueue.main.async { completion(.success(CapturedTabs(links: links, closeTarget: tabs.first?.closeTarget))) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}
private final class CaptureOutput: @unchecked Sendable { var data = Data() }
