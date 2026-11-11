#if DEBUG
import AppKit
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
        let directory = URL(fileURLWithPath: "/tmp/snlive-" + UUID().uuidString.prefix(12), isDirectory: true)
        let browsing = AutomationBrowser(), model = AppModel()
        let controller = AutomationController(model: model, directory: directory, browsing: browsing)
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
            for (id, name) in [("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome")] {
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                    throw Failure(browser: name, code: "UNSUPPORTED_browser_not_installed")
                }
                // Check existing access before opening a fixture whenever the browser is already running.
                _ = try await snapshot(browsing, browser: name)
                let nonce = UUID().uuidString.lowercased()
                let url = URL(string: "https://example.com/?savenest-mcp-test=" + nonce)!
                fixtureURLs.insert(url.absoluteString)
                print("MCP browser check \(name): opening disposable fixture")
                try await open(url, application: application, browser: name)
                let target = try await findFixture(browsing, browserID: id, name: name, url: url.absoluteString)
                knownTargets.append(target)

                let search = try await call("search_links", ["sources": .array([.string("open")]), "query": .string(nonce),
                    "filters": .object(["browser": .string(name)])], browser: name)
                guard let rows = search["items"]?.array, rows.count == 1,
                      let row = rows.first?.object, row["url"]?.string == url.absoluteString,
                      row["tab_ref"]?.string == target.reference else {
                    throw Failure(browser: name, code: "fixture_search_did_not_match_exact_reference")
                }
                let selection: AutomationValue = .array([.object(["tab_ref": .string(target.reference)])])
                let focused = try await call("open_links", ["targets": selection], browser: name)
                try completed(focused, browser: name, stage: "focus")
                // Preserve the original reference; every browser operation must revalidate it.
                let before = model.library.links.count
                let saved = try await call("save_tabs", ["tabs": selection, "close_after": .bool(true),
                    "note": .string("Disposable live browser check"), "tags": .array([.string("mcp-smoke-fixture")])], browser: name)
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

    private static func completed(_ result: [String: AutomationValue], browser: String, stage: String) throws {
        guard result["completed"]?.int == 1, result["failed"]?.int == 0 else {
            let code = result["items"]?.array?.first?.object?["code"]?.string ?? "incomplete"
            throw Failure(browser: browser, code: stage + ":" + code)
        }
    }

    private static func snapshot(_ browsing: AutomationBrowser, browser: String) async throws -> [AutomationTab] {
        let snapshot = try await browsing.snapshot()
        guard snapshot.warnings.isEmpty else {
            // Warnings contain only fixed browser names and recovery text, never page data.
            for warning in snapshot.warnings { print("MCP browser check UNSUPPORTED: " + warning) }
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
