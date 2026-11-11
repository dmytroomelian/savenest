#if DEBUG
import AppKit
import Darwin
import SaveNestCore

/// Explicit release smoke check. Only nonce-marked disposable tabs may become action targets.
@MainActor
enum AutomationLiveBrowserChecks {
    private struct Failure: LocalizedError {
        let browser: String
        let code: String
        var errorDescription: String? { "\(browser): \(code)" }
    }

    static func run() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard AppLaunch.isPreview, arguments.contains("--ui-preview"), arguments.contains("--automation-browser-checks") else {
            throw Failure(browser: "Setup", code: "requires_explicit_preview_and_browser_check_flags")
        }
        try checkProcessIdentity()
        let browserFlags = arguments.filter { $0.hasPrefix("--automation-browser=") }
        guard browserFlags.count <= 1 else { throw Failure(browser: "Setup", code: "choose_one_browser_filter") }
        let selectedBrowser = browserFlags.first.map { String($0.dropFirst("--automation-browser=".count)) }
        guard selectedBrowser == nil || ["Safari", "Chrome"].contains(selectedBrowser!) else {
            throw Failure(browser: "Setup", code: "browser_filter_must_be_Safari_or_Chrome")
        }
        let browsers = [("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome")]
            .filter { selectedBrowser == nil || $0.1 == selectedBrowser }
        let directory = URL(fileURLWithPath: "/tmp/snlive-" + UUID().uuidString.prefix(12), isDirectory: true)
        let browsing = AutomationBrowser(), model = AppModel()
        let controller = AutomationController(model: model, directory: directory, browsing: browsing)
        var lastSnapshot: [AutomationTab] = [], lastWarnings: [String] = []
        var observedTarget: AutomationTab?, lastProcessObservation: String?
        browsing.snapshotObserverForTesting = {
            lastSnapshot = $0; lastWarnings = $1
            lastProcessObservation = observedTarget.map(processObservation)
        }
        var knownTargets: [AutomationTab] = []
        var fixtureURLs = Set<String>()
        defer {
            controller.stop()
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { print("MCP browser check cleanup: temporary_directory_removal_failed") }
        }
        controller.testUser = { "live-browser-disposable-fixture" }
        try controller.startForTesting()
        await controller.addClient(name: "Disposable browser check")
        guard let client = controller.clients.first else { throw Failure(browser: "Setup", code: "fixture_client_unavailable") }
        for permission in [AutomationPermission.tabsRead, .libraryEdit, .openLinks, .saveAndClose] {
            controller.setPermission(permission, allowed: true, clientID: client.id)
        }
        let credential = try JSONDecoder().decode([String: String].self, from: AutomationPrivateFiles.read(controller.credentialURL(client)))
        guard let token = credential["token"] else { throw Failure(browser: "Setup", code: "fixture_credential_unavailable") }

        func call(_ tool: String, _ arguments: [String: AutomationValue], browser: String) async throws -> [String: AutomationValue] {
            var arguments = arguments
            if tool != "search_links" { arguments["request_id"] = .string(UUID().uuidString) }
            let response = await controller.handle(.init(id: UUID().uuidString, token: token, tool: tool, arguments: arguments))
            if let error = response.error { throw Failure(browser: browser, code: tool + ":" + error.code) }
            guard let result = response.result else { throw Failure(browser: browser, code: tool + ":missing_result") }
            return result
        }

        do {
            for (id, name) in browsers {
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                    throw Failure(browser: name, code: "UNSUPPORTED_browser_not_installed")
                }
                // Check existing access before opening a fixture whenever the browser is already running.
                observedTarget = nil
                let baseline = try await snapshot(browsing, browser: name)
                observedTarget = baseline.first { $0.tab.browserID == id }
                let repeated = try await snapshot(browsing, browser: name)
                try stableEnumeration(baseline, repeated, browserID: id, name: name, processObservation: lastProcessObservation)
                observedTarget = nil
                let nonce = UUID().uuidString.lowercased()
                let url = URL(string: "https://example.com/?savenest-mcp-test=" + nonce)!
                fixtureURLs.insert(url.absoluteString)
                print("MCP browser check \(name): opening disposable fixture")
                try await open(url, application: application, browser: name)
                let target = try await findFixture(browsing, browserID: id, name: name, url: url.absoluteString)
                knownTargets.append(target)
                observedTarget = target

                let search = try await call("search_links", ["sources": .array([.string("open")]), "query": .string(nonce),
                    "filters": .object(["browser": .string(name)])], browser: name)
                let rows = search["items"]?.array ?? []
                guard rows.count == 1,
                      let row = rows.first?.object, row["url"]?.string == url.absoluteString,
                      row["tab_ref"]?.string == target.reference else {
                    print("MCP fixture search diagnostic: results=\(rows.count) exact_url_matches=\(rows.filter { $0.object?["url"]?.string == url.absoluteString }.count) exact_reference_matches=\(rows.filter { $0.object?["tab_ref"]?.string == target.reference }.count)")
                    diagnose(target, snapshot: lastSnapshot, warnings: lastWarnings, result: search, observedProcess: lastProcessObservation)
                    throw Failure(browser: name, code: "fixture_search_did_not_match_exact_reference")
                }
                let selection: AutomationValue = .array([.object(["tab_ref": .string(target.reference)])])
                let focused = try await call("open_links", ["targets": selection], browser: name)
                if focused["failed"]?.int != 0 {
                    diagnose(target, snapshot: lastSnapshot, warnings: lastWarnings, result: focused, observedProcess: lastProcessObservation)
                }
                try completed(focused, browser: name, stage: "focus")
                // Preserve the original reference; every browser operation must revalidate it.
                let before = model.library.links.count
                let saved = try await call("save_tabs", ["tabs": selection, "close_after": .bool(true),
                    "note": .string("Disposable live browser check"), "tags": .array([.string("mcp-smoke-fixture")])], browser: name)
                if saved["failed"]?.int != 0 {
                    diagnose(target, snapshot: lastSnapshot, warnings: lastWarnings, result: saved, observedProcess: lastProcessObservation)
                }
                try completed(saved, browser: name, stage: "save_and_close")
                guard let item = saved["items"]?.array?.first?.object,
                      item["saved"]?.bool == true, item["closed"]?.bool == true,
                      model.library.links.count == before + 1,
                      model.library.links.contains(where: { $0.url == url.absoluteString && $0.note == "Disposable live browser check" }) else {
                    throw Failure(browser: name, code: "preview_library_save_not_verified")
                }
                let remaining = try await snapshot(browsing, browser: name)
                guard !remaining.contains(where: { $0.tab.browserID == id && $0.tab.url == url.absoluteString }) else {
                    throw Failure(browser: name, code: "fixture_still_open_after_close")
                }
                let closedAgain = try await browsing.close(target)
                guard !closedAgain else {
                    throw Failure(browser: name, code: "already_closed_reference_was_not_refused")
                }
                knownTargets.removeAll { $0.reference == target.reference }
                fixtureURLs.remove(url.absoluteString)
                print("MCP browser check \(name): PASS snapshot, focus, preview save, verified close, already-closed refusal")
            }
        } catch {
            // Never rediscover a target for cleanup. Navigation, reordering, restart, or ambiguity leaves it open.
            for target in knownTargets where fixtureURLs.contains(target.tab.url) {
                do {
                    if try await browsing.close(target) { fixtureURLs.remove(target.tab.url) }
                } catch { /* Unverified or changed fixtures are deliberately left open. */ }
            }
            if !fixtureURLs.isEmpty { print("MCP browser check cleanup: unverified disposable fixtures may remain open; existing tabs were not targeted") }
            throw error
        }
    }

    /// Also callable by the fixture-only integration suite; reads only this test process.
    static func checkProcessIdentity() throws {
        let pid = getpid()
        guard let birth = AutomationProcessBirth.read(pid) else { throw Failure(browser: "Process identity", code: "current_kernel_birth_unavailable") }
        for _ in 0..<100 {
            guard AutomationProcessBirth.read(pid) == birth, AutomationProcessBirth.matches(birth, processID: pid) else {
                throw Failure(browser: "Process identity", code: "kernel_birth_changed_within_same_process")
            }
        }
        let reused = AutomationProcessBirth(processID: pid, seconds: birth.seconds + 1, microseconds: birth.microseconds)
        let otherPID = AutomationProcessBirth(processID: pid + 1, seconds: birth.seconds, microseconds: birth.microseconds)
        guard !AutomationProcessBirth.matches(reused, processID: pid),
              !AutomationProcessBirth.matches(otherPID, processID: pid),
              !AutomationProcessBirth.matches(nil, processID: pid),
              AutomationProcessBirth.read(0) == nil, AutomationProcessBirth.read(-1) == nil,
              AutomationProcessBirth.read(pid_t.max) == nil else {
            throw Failure(browser: "Process identity", code: "missing_or_stale_kernel_birth_was_accepted")
        }
        print("Passed kernel process identity checks")
        try checkTabReferences()
    }

    static func checkTabReferences() throws {
        let birth = AutomationProcessBirth(processID: 123, seconds: 1_800_000_000, microseconds: 42)
        func tab(index: Int = 1, window: String = "fixture-window", id: String = "fixture-tab", url: String = "https://example.test/fixture") -> OpenBrowserTab {
            .init(browserID: "com.google.Chrome", browserName: "Chrome", windowID: window, tabID: id, index: index, title: "Fixture", url: url)
        }
        func reference(_ tab: OpenBrowserTab, _ stamp: AutomationProcessBirth? = nil, safari: Bool = false, session: String = "fixture-session") -> String {
            AutomationTabReference.make(tab: tab, birth: stamp ?? birth, session: session, safari: safari)
        }
        let chromium = reference(tab()), safari = reference(tab(id: ""), safari: true)
        guard chromium == reference(tab(index: 8)),
              safari != reference(tab(index: 8, id: ""), safari: true),
              chromium != reference(tab(url: "https://example.test/navigated")),
              chromium != reference(tab(window: "different-window")),
              chromium != reference(tab(id: "different-tab")),
              chromium != reference(tab(), .init(processID: 124, seconds: birth.seconds, microseconds: birth.microseconds)),
              chromium != reference(tab(), .init(processID: birth.processID, seconds: birth.seconds + 1, microseconds: birth.microseconds)),
              chromium != reference(tab(), .init(processID: birth.processID, seconds: birth.seconds, microseconds: birth.microseconds + 1)),
              chromium != reference(tab(), session: "different-session") else {
            throw Failure(browser: "Tab identity", code: "reference_movement_or_restart_regression")
        }
        print("Passed tab reference checks: Chromium reorder, Safari position, navigation, window, tab, process birth, session")
    }

    private static func completed(_ result: [String: AutomationValue], browser: String, stage: String) throws {
        guard result["completed"]?.int == 1, result["failed"]?.int == 0 else {
            let code = result["items"]?.array?.first?.object?["code"]?.string ?? "incomplete"
            throw Failure(browser: browser, code: stage + ":" + code)
        }
    }

    /// Compare only the disposable fixture. Never print page data, references, or absolute launch times.
    private static func diagnose(_ target: AutomationTab, snapshot: [AutomationTab], warnings: [String], result: [String: AutomationValue], observedProcess: String?) {
        let sameURL = snapshot.filter { $0.tab.browserID == target.tab.browserID && $0.tab.url == target.tab.url }
        let sameLocation = snapshot.filter {
            $0.tab.browserID == target.tab.browserID && $0.tab.windowID == target.tab.windowID &&
            (target.tab.tabID.isEmpty ? $0.tab.index == target.tab.index : $0.tab.tabID == target.tab.tabID)
        }
        let candidate = sameURL.count == 1 ? sameURL.first : (sameLocation.count == 1 ? sameLocation.first : nil)
        let saved = result["items"]?.array?.first?.object?["saved"]?.bool == true
        print("MCP fixture diagnostic: exact_url_matches=\(sameURL.count) original_location_matches=\(sameLocation.count) saved=\(saved)")
        if let candidate {
            print("MCP fixture identity: target_pid=\(target.processID) current_pid=\(candidate.processID) reference_same=\(candidate.reference == target.reference) process_same=\(candidate.processID == target.processID) launch_same=\(candidate.launchedAt == target.launchedAt) launch_delta_ms=\(launchDelta(candidate.launchedAt, target.launchedAt)) window_same=\(candidate.tab.windowID == target.tab.windowID) tab_same=\(candidate.tab.tabID == target.tab.tabID) index_same=\(candidate.tab.index == target.tab.index) url_same=\(candidate.tab.url == target.tab.url)")
        }
        if let observedProcess { print("MCP process at snapshot: " + observedProcess) }
        print("MCP process at failure: " + processObservation(target))
        for warning in warnings { print("MCP fixture snapshot warning: " + warning) }
    }

    private static func processObservation(_ target: AutomationTab) -> String {
        let process = NSRunningApplication(processIdentifier: target.processID)
        let nativePIDs = NSRunningApplication.runningApplications(withBundleIdentifier: target.tab.browserID).filter { !$0.isTerminated }.map(\.processIdentifier)
        let workspacePIDs = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleIdentifier == target.tab.browserID }.map(\.processIdentifier)
        let alive = kill(target.processID, 0) == 0 || errno == EPERM
        return "target_pid=\(target.processID) lookup_pid=\(process?.processIdentifier ?? -1) process_found=\(process != nil) running=\(process?.isTerminated == false) kernel_alive=\(alive) launch_same=\(process?.launchDate == target.launchedAt) launch_delta_ms=\(launchDelta(process?.launchDate, target.launchedAt)) native_pids=\(nativePIDs) workspace_pids=\(workspacePIDs)"
    }

    private static func launchDelta(_ current: Date?, _ previous: Date?) -> String {
        guard let current, let previous else { return "unknown" }
        return String(format: "%.9f", abs(current.timeIntervalSince(previous)) * 1_000)
    }

    /// Read-only preflight can expose unstable process identity without opening another fixture.
    private static func stableEnumeration(_ before: [AutomationTab], _ after: [AutomationTab], browserID: String, name: String, processObservation: String?) throws {
        let prior = before.filter { $0.tab.browserID == browserID }, current = after.filter { $0.tab.browserID == browserID }
        for target in prior {
            guard let next = current.first(where: { $0.tab.contextKey == target.tab.contextKey }) else { continue }
            if target.reference != next.reference {
                print("MCP enumeration diagnostic: unchanged_tab_identity=true reference_same=false target_pid=\(target.processID) current_pid=\(next.processID) launch_same=\(target.launchedAt == next.launchedAt) launch_delta_ms=\(launchDelta(next.launchedAt, target.launchedAt))")
                if let processObservation { print("MCP process at snapshot: " + processObservation) }
                throw Failure(browser: name, code: "unstable_reference_before_fixture")
            }
        }
        if !prior.isEmpty && current.isEmpty {
            if let processObservation { print("MCP process at snapshot: " + processObservation) }
            throw Failure(browser: name, code: "browser_disappeared_from_snapshot_before_fixture")
        }
    }

    private static func snapshot(_ browsing: AutomationBrowser, browser: String) async throws -> [AutomationTab] {
        let snapshot = try await browsing.snapshot()
        let relevantWarnings = snapshot.warnings.filter {
            $0.hasPrefix(browser + " could not be read.") || $0 == "Quit duplicate copies of \(browser) before using its tabs."
        }
        guard relevantWarnings.isEmpty else {
            // Warnings contain only fixed browser names and recovery text, never page data.
            for warning in relevantWarnings { print("MCP browser check UNSUPPORTED: " + warning) }
            throw Failure(browser: browser, code: "UNSUPPORTED_snapshot_access_or_scripting_unavailable")
        }
        return snapshot.tabs
    }

    private static func findFixture(_ browsing: AutomationBrowser, browserID: String, name: String, url: String) async throws -> AutomationTab {
        for _ in 0..<20 {
            try Task.checkCancellation()
            let matches = try await snapshot(browsing, browser: name).filter { $0.tab.browserID == browserID && $0.tab.url == url }
            if matches.count == 1 { return matches[0] }
            guard matches.isEmpty else { throw Failure(browser: name, code: "ambiguous_fixture_left_open") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw Failure(browser: name, code: "fixture_not_visible_after_open")
    }

    private static func open(_ url: URL, application: URL, browser: String) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
                if error != nil { continuation.resume(throwing: Failure(browser: browser, code: "UNSUPPORTED_application_open_failed")) }
                else { continuation.resume() }
            }
        }
    }
}
#endif
