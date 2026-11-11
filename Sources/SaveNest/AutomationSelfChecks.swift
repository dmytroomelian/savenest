#if DEBUG
import Foundation
import Darwin
import SaveNestCore

/// Runs only against the sample library and disposable credentials. Never scripts a browser.
@MainActor
enum AutomationSelfChecks {
    private struct Failed: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failed(errorDescription: "MCP integration check failed: " + message) }
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failed(errorDescription: "MCP integration check timed out waiting for the fixture.")
    }

    static func run() async throws {
        try AutomationLiveBrowserChecks.checkProcessIdentity()
        guard AppLaunch.isPreview else { throw Failed(errorDescription: "MCP checks require --ui-preview.") }
        try await AutomationClientInstallerChecks.run()
        try await checkConnectionSetup()
        let directory = URL(fileURLWithPath: "/tmp/snmcp-" + UUID().uuidString.prefix(12), isDirectory: true)
        let model = AppModel(), browsing = FakeBrowser()
        let controller = AutomationController(model: model, directory: directory, browsing: browsing)
        defer { controller.stop(); try? FileManager.default.removeItem(at: directory) }
        var user = "fixture-account", online = true
        controller.testUser = {
            guard online else { throw AutomationFailure("pro_required", "Fixture Pro verification unavailable.") }
            return user
        }
        try controller.startForTesting()
        try expect(controller.listening, "private server starts")
        await controller.addClient(name: "Fixture Codex")
        guard let client = controller.clients.first else { throw Failed(errorDescription: "Fixture connection was not created.") }
        let credential = try JSONDecoder().decode([String: String].self, from: AutomationPrivateFiles.read(controller.credentialURL(client)))
        guard let token = credential["token"] else { throw Failed(errorDescription: "Fixture credential is missing.") }
        var info = stat()
        try expect(lstat(controller.socketPath, &info) == 0 && info.st_mode & 0o777 == 0o600, "socket mode is 0600")
        try expect(lstat(controller.credentialURL(client).path, &info) == 0 && info.st_mode & 0o777 == 0o600, "credential mode is 0600")
        try expect(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "storage mode is 0700")

        func request(_ tool: String, _ arguments: [String: AutomationValue] = [:], id: String = UUID().uuidString) -> AutomationSocketRequest {
            var args = arguments
            if !["get_status", "search_links", "get_links", "cancel"].contains(tool), args["request_id"] == nil { args["request_id"] = .string(UUID().uuidString) }
            return .init(id: id, token: token, tool: tool, arguments: args)
        }
        func call(_ tool: String, _ arguments: [String: AutomationValue] = [:]) async -> AutomationSocketResponse {
            await controller.handle(request(tool, arguments))
        }
        func grant(_ permission: AutomationPermission, _ allowed: Bool = true) { controller.setPermission(permission, allowed: allowed, clientID: client.id) }
        func tabTargets() -> AutomationValue { .array(browsing.tabs.map { .object(["tab_ref": .string($0.reference)]) }) }

        let socketPath = controller.socketPath, statusRequest = request("get_status")
        let status = try await Task.detached { try socketRoundTrip(path: socketPath, request: statusRequest) }.value
        try expect(status.error == nil && status.result?["pro_verified"]?.bool == true, "real Unix transport authenticates")
        let forged = await controller.handle(.init(id: "bad", token: "invalid", tool: "search_links", arguments: [:]))
        try expect(forged.error?.code == "unauthorized", "invalid token rejected")
        let denied = await call("add_links", ["items": .array([.object(["url": .string("https://mcp-fixture.test/denied")])])])
        try expect(denied.error?.code == "permission_denied", "default connection cannot write")
        let tabsDenied = await call("search_links", ["sources": .array([.string("open")])])
        try expect(tabsDenied.error?.code == "permission_denied" && browsing.snapshotCalls == 0, "tab access denied before enumeration")

        for permission in AutomationPermission.allCases { grant(permission) }
        let before = model.library
        let add = request("add_links", ["request_id": .string("repeat-safe"), "items": .array([.object(["url": .string("https://mcp-fixture.test/new"), "note": .string("Preserve this note")])])])
        let saved = await controller.handle(add)
        try expect(saved.error == nil && saved.result?["completed"]?.int == 1, "authorized save commits")
        let generation = model.automationGeneration
        let replay = await controller.handle(.init(id: "replay", token: token, tool: add.tool, arguments: add.arguments))
        try expect(replay.result == saved.result && model.automationGeneration == generation, "retry returns exact result without committing twice")
        var changedArguments = add.arguments; changedArguments["items"] = .array([.object(["url": .string("https://mcp-fixture.test/different")])])
        let collision = await controller.handle(.init(id: "collision", token: token, tool: add.tool, arguments: changedArguments))
        try expect(collision.error?.code == "request_conflict", "request ID cannot be reused for a different mutation")

        online = false
        let outage = await controller.handle(.init(id: "outage", token: token, tool: add.tool, arguments: add.arguments))
        try expect(outage.error?.code == "pro_required", "cached writes still require online Pro verification")
        online = true; user = "another-account"
        let switched = await call("search_links")
        try expect(switched.error?.code == "permission_denied", "credential cannot cross accounts")
        user = "fixture-account"
        guard let record = saved.result?["items"]?.array?.first?.object?["record"]?.object,
              let id = record["id"]?.string, let revision = record["revision"]?.string,
              let tokenUndo = saved.result?["operation_token"]?.string else { throw Failed(errorDescription: "Save result has no revision or undo token.") }
        let undone = await call("undo_change", ["operation_token": .string(tokenUndo)])
        try expect(undone.error == nil && model.library == before, "undo restores the exact committed library")
        let missingUndo = await call("undo_change", ["operation_token": .string(tokenUndo)])
        try expect(missingUndo.error?.code == "undo_expired", "undo token is consumed")

        let savedAgain = await call("add_links", ["items": .array([.object(["url": .string("https://mcp-fixture.test/concurrent")])])])
        let staleToken = savedAgain.result?["operation_token"]?.string ?? ""
        var userEdit = model.library
        _ = userEdit.insert([SavedLink(url: "https://mcp-fixture.test/ui", title: "UI change")])
        try expect(model.automationCommit(userEdit), "fixture UI edit commits")
        let concurrentUndo = await call("undo_change", ["operation_token": .string(staleToken)])
        try expect(concurrentUndo.error?.code == "undo_expired" && model.library == userEdit, "undo cannot discard a later UI change")
        // Missing records and old revisions must not silently apply a guessed mutation.
        let stale = await call("update_links", ["items": .array([.object(["id": .string(id), "revision": .string(revision), "note": .string("Wrong update")])])])
        try expect(stale.result?["failed"]?.int == 1 && model.library == userEdit, "removed record is rejected")
        let existing = model.library.links[0], oldRevision = AutomationLibrary.revision(model.library.links[0])
        var outsideEdit = model.library; outsideEdit.links[0].note = "Changed outside MCP"
        try expect(model.automationCommit(outsideEdit), "concurrent record edit commits")
        let staleRevision = await call("remove_links", ["items": .array([.object(["id": .string(existing.id.uuidString), "revision": .string(oldRevision)])])])
        try expect(staleRevision.result?["items"]?.array?.first?.object?["code"]?.string == "stale_revision", "stale revision rejected by native path")

        var staleEditor = model.library.links[0]
        let editorRevision = AutomationLibrary.revision(staleEditor)
        staleEditor.note = "Unsaved native editor draft"
        let editedByMCP = await call("update_links", ["items": .array([.object(["id": .string(staleEditor.id.uuidString), "revision": .string(editorRevision), "note": .string("New note saved by MCP")])])])
        try expect(editedByMCP.result?["completed"]?.int == 1, "MCP updates the record while a native draft is open")
        let editorSaved = await model.update(staleEditor, expectedRevision: editorRevision)
        try expect(!editorSaved && model.library.links.first(where: { $0.id == staleEditor.id })?.note == "New note saved by MCP", "stale native editor cannot overwrite the newer MCP note")
        let captureSaved = await model.saveWorkspaceLink(staleEditor, expectedRevision: editorRevision)
        try expect(!captureSaved && model.library.links.first(where: { $0.id == staleEditor.id })?.note == "New note saved by MCP", "stale captured draft cannot overwrite the newer MCP note")

        // Existing/imported records can exceed the edit limit. Transport must return a
        // structured error rather than writing an enormous response or silently truncating it.
        do {
            let beforeLargeRecord = model.library
            defer { _ = model.automationCommit(beforeLargeRecord) }
            var oversized = SavedLink(url: "https://mcp-fixture.test/oversized-import", title: "Oversized imported note")
            oversized.note = String(repeating: "x", count: 16 * 1024 * 1024)
            var largeLibrary = model.library; _ = largeLibrary.insert([oversized])
            try expect(model.automationCommit(largeLibrary), "oversized imported fixture added")
            let largeRequest = request("get_links", ["ids": .array([.string(oversized.id.uuidString)])])
            let largeResponse = try await Task.detached { try socketRoundTrip(path: socketPath, request: largeRequest) }.value
            try expect(largeResponse.error?.code == "response_too_large" && largeResponse.result == nil, "oversized response returns a structured transport error")
        }

        // Concurrent clients share one library owner but have independent request IDs and undo authority.
        await controller.addClient(name: "Fixture Claude")
        guard let second = controller.clients.first(where: { $0.id != client.id }) else { throw Failed(errorDescription: "Second fixture connection was not created.") }
        let secondCredential = try JSONDecoder().decode([String: String].self, from: AutomationPrivateFiles.read(controller.credentialURL(second)))
        guard let secondToken = secondCredential["token"] else { throw Failed(errorDescription: "Second fixture credential is missing.") }
        controller.setPermission(.libraryEdit, allowed: true, clientID: second.id)
        let parallelA = Task { await call("add_links", ["request_id": .string("shared-request-id"), "items": .array([.object(["url": .string("https://mcp-fixture.test/client-a"), "note": .string("Client A")])])]) }
        let parallelB = Task { await controller.handle(.init(id: "client-b-transport", token: secondToken, tool: "add_links", arguments: ["request_id": .string("shared-request-id"), "items": .array([.object(["url": .string("https://mcp-fixture.test/client-b"), "note": .string("Client B")])])])) }
        let resultA = await parallelA.value, resultB = await parallelB.value
        try expect(resultA.result?["completed"]?.int == 1 && resultB.result?["completed"]?.int == 1, "clients can reuse request IDs independently")
        try expect(model.library.links.first(where: { $0.url == "https://mcp-fixture.test/client-a" })?.note == "Client A", "first concurrent write survives")
        try expect(model.library.links.first(where: { $0.url == "https://mcp-fixture.test/client-b" })?.note == "Client B", "second concurrent write survives")
        let beforeSecondUndo = model.library
        let secondWrite = await controller.handle(.init(id: "client-b-undo-source", token: secondToken, tool: "add_links", arguments: ["request_id": .string("second-undo-source"), "items": .array([.object(["url": .string("https://mcp-fixture.test/client-b-undo")])])]))
        guard let secondUndo = secondWrite.result?["operation_token"]?.string else { throw Failed(errorDescription: "Second client did not receive an undo token.") }
        let foreignUndo = await call("undo_change", ["operation_token": .string(secondUndo)])
        try expect(foreignUndo.error?.code == "undo_expired", "one client cannot consume another client's valid undo token")
        let ownUndo = await controller.handle(.init(id: "client-b-undo", token: secondToken, tool: "undo_change", arguments: ["request_id": .string("second-undo"), "operation_token": .string(secondUndo)]))
        try expect(ownUndo.error == nil && model.library == beforeSecondUndo, "own undo remains usable after foreign attempt and preserves other client writes")
        controller.revoke(second)

        let historyWasEnabled = model.tabSearch.historyEnabled
        model.tabSearch.historyEnabled = true
        var historyStarted = false, releaseHistory = false
        browsing.onHistory = {
            historyStarted = true
            while !releaseHistory { try await Task.sleep(nanoseconds: 1_000_000) }
            return ([.init(url: "https://mcp-fixture.test/history", title: "Private fixture history", browser: "Safari", lastVisited: Date())], [])
        }
        let readingHistory = Task { await call("search_links", ["sources": .array([.string("history")])]) }
        try await waitUntil { historyStarted }
        model.tabSearch.historyEnabled = false; releaseHistory = true
        let disabledHistory = await readingHistory.value
        browsing.onHistory = nil; model.tabSearch.historyEnabled = historyWasEnabled
        try expect(disabledHistory.error?.code == "history_disabled" && disabledHistory.result == nil, "history disabled during a read returns no history data")

        model.tabSearch.historyEnabled = true
        browsing.tabs = makeTabs()
        let historyTab = browsing.tabs[0]
        browsing.onHistory = { ([.init(url: historyTab.tab.url, title: "Already open history page", browser: "Safari", lastVisited: Date())], []) }
        let historySearch = await call("search_links", ["sources": .array([.string("history")])])
        guard let historyRef = historySearch.result?["items"]?.array?.first?.object?["history_ref"]?.string else { throw Failed(errorDescription: "History fixture search did not return a reference.") }
        let openedBeforeHistory = browsing.opened.count, activatedBeforeHistory = browsing.activated.count
        let historyOpen = await call("open_links", ["targets": .array([.object(["history_ref": .string(historyRef)])])])
        browsing.onHistory = nil; model.tabSearch.historyEnabled = historyWasEnabled
        try expect(historyOpen.result?["completed"]?.int == 1 && browsing.activated.count == activatedBeforeHistory + 1, "opening history activates an existing matching tab")
        try expect(browsing.activated.last == historyTab.reference && browsing.opened.count == openedBeforeHistory, "history open does not create a duplicate tab when tab access is granted")

        browsing.tabs = makeTabs()
        let search = await call("search_links", ["sources": .array([.string("open")])])
        try expect(search.result?["total"]?.int == 3, "open tab search returns distinct references")
        let failBefore = model.library
        model.automationWriteFailsForTesting = true
        let failedSave = await call("save_tabs", ["tabs": tabTargets(), "close_after": .bool(true)])
        model.automationWriteFailsForTesting = false
        try expect(failedSave.result?["failed"]?.int == 3 && model.library == failBefore, "failed saves report failure without library changes")
        try expect(browsing.closed.isEmpty, "failed saves never close tabs")
        let malformedClose = await call("close_tabs", ["tabs": tabTargets(), "close_after": .bool(true)])
        try expect(malformedClose.error?.code == "invalid_arguments" && browsing.closed.isEmpty, "unknown close_tabs fields are rejected before any tab action")
        grant(.closeTabs, false)
        let deniedClose = await call("close_tabs", ["tabs": tabTargets()])
        try expect(deniedClose.error?.code == "permission_denied" && browsing.closed.isEmpty, "direct closing has a separate permission")
        let savedClosed = await call("save_tabs", ["tabs": tabTargets(), "close_after": .bool(true)])
        try expect(savedClosed.result?["completed"]?.int == 3 && browsing.closed.count == 3, "save-and-close works without direct-close permission")

        browsing.tabs = makeTabs(); browsing.closed = []; browsing.closeAttempts = 0
        grant(.closeTabs)
        _ = await call("search_links", ["sources": .array([.string("open")])])
        browsing.onClose = { _ in
            if browsing.closeAttempts == 2 { try await Task.sleep(nanoseconds: 10_000_000_000) }
            return true
        }
        let closeRequest = request("close_tabs", ["tabs": tabTargets()], id: "cancel-this-transport")
        let closing = Task { await controller.handle(closeRequest) }
        try await waitUntil { browsing.closeAttempts == 2 }
        _ = await call("cancel", ["request_id": .string(closeRequest.id)])
        let partial = await closing.value
        try expect(browsing.closed.count == 1 && browsing.closeAttempts == 2, "cancellation stops all remaining tab actions")
        try expect(partial.result?["completed"]?.int == 1 && partial.result?["failed"]?.int == 2, "partial results identify completed and cancelled targets")

        // A second transport waiting on the same mutation must remain cancellable.
        browsing.tabs = makeTabs(); browsing.closed = []; browsing.closeAttempts = 0
        let aliasOriginal = request("close_tabs", ["tabs": tabTargets(), "request_id": .string("pending-alias")], id: "alias-origin")
        let originalRun = Task { await controller.handle(aliasOriginal) }
        try await waitUntil { browsing.closeAttempts == 2 }
        let aliasRequest = AutomationSocketRequest(id: "alias-joined", token: token, tool: aliasOriginal.tool, arguments: aliasOriginal.arguments)
        let aliasRun = Task { await controller.handle(aliasRequest) }
        try await waitUntil { controller.hasRunningRequestForTesting(clientID: client.id, requestID: aliasRequest.id) }
        _ = await call("cancel", ["request_id": .string(aliasRequest.id)])
        let originalResult = await originalRun.value, aliasResult = await aliasRun.value
        try expect(browsing.closed.count == 1 && browsing.closeAttempts == 2, "cancelling a pending alias stops shared work")
        try expect(originalResult.result?["completed"]?.int == 1 && aliasResult.result == originalResult.result, "pending aliases receive the same partial result")

        // A socket disconnect must propagate to the same running native operation.
        browsing.tabs = makeTabs(); browsing.closed = []; browsing.closeAttempts = 0
        let cancellationsBeforeDisconnect = browsing.cancelledCloses
        browsing.onClose = { _ in try await Task.sleep(nanoseconds: 10_000_000_000); return true }
        let disconnectRequest = request("close_tabs", ["tabs": tabTargets()])
        let fd = try await Task.detached { try socketSend(path: socketPath, request: disconnectRequest) }.value
        try await waitUntil { browsing.closeAttempts == 1 }
        Darwin.close(fd)
        try await waitUntil { browsing.cancelledCloses > cancellationsBeforeDisconnect }
        try expect(browsing.closed.isEmpty && browsing.closeAttempts == 1, "disconnected socket cancels outstanding work")
        browsing.onClose = nil

        // Revoking open permission while activation is suspended must prevent fallback opening.
        let savedTab = model.library.links.first(where: { $0.url == browsing.tabs[0].tab.url })!
        browsing.activationStarted = false
        browsing.onActivate = { _ in
            browsing.activationStarted = true
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return false
        }
        let opening = Task { await call("open_links", ["targets": .array([.object(["id": .string(savedTab.id.uuidString)])])]) }
        try await waitUntil { browsing.activationStarted }
        grant(.openLinks, false)
        _ = await opening.value
        try expect(browsing.opened.isEmpty, "revocation prevents an open fallback after a suspended activation")
        browsing.onActivate = nil

        controller.revoke(client)
        let revoked = await call("search_links")
        try expect(revoked.error?.code == "unauthorized", "revoked token is rejected")
        try expect(!FileManager.default.fileExists(atPath: controller.credentialURL(client).path), "revocation removes local credential")
        let reloaded = AutomationController(model: model, directory: directory, browsing: browsing)
        try expect(reloaded.clients.isEmpty, "revocation persists across controller restart")
        print("Passed MCP native integration checks: private socket, credentials, permissions, Pro, account isolation, concurrent clients, retries, revisions, undo, history revocation, save failures, and cancellation.")
    }

    private static func checkConnectionSetup() async throws {
        let directory = URL(fileURLWithPath: "/tmp/snsetup-" + UUID().uuidString.prefix(10), isDirectory: true)
        let model = AppModel()
        let controller = AutomationController(model: model, directory: directory, browsing: FakeBrowser())
        defer { controller.stop(); controller.testInstaller = nil; try? FileManager.default.removeItem(at: directory); withExtendedLifetime(model) {} }
        var online = true, failInstall = true, switchAccount = false, calls = 0, user = "setup-user"
        controller.testUser = {
            guard online else { throw AutomationFailure("pro_required", "Fixture offline.") }
            return user
        }
        controller.testAdapterURL = directory.appendingPathComponent("fixture-adapter")
        controller.testInstaller = { _, _, credential in
            calls += 1
            try expect(FileManager.default.fileExists(atPath: credential.path), "setup creates private credential before installing")
            if failInstall { throw AutomationFailure("install_failed", "Fixture installation failed.") }
            if switchAccount { user = "different-user" }
            return "Setup saved. Restart your AI app."
        }
        await controller.connect(.codex)
        try expect(calls == 1 && controller.clients.isEmpty && !controller.enabled, "failed setup removes new credential and restores disabled state")
        failInstall = false
        await controller.connect(.codex)
        guard let client = controller.clients.first else { throw Failed(errorDescription: "One-click setup did not create a client.") }
        try expect(controller.enabled && controller.listening && client.configuredAt != nil, "one click enables and installs setup")
        try expect(client.permissions == [.libraryRead], "one-click setup grants only saved-library reading")
        try expect(controller.activeClients.isEmpty, "installed configuration does not claim a live AI connection")
        await controller.connect(.codex)
        try expect(controller.clients.count == 1 && controller.clients.first?.id == client.id, "reconnecting reuses its credential")
        controller.setPermission(.tabsRead, allowed: true, clientID: client.id)
        let oldCredential = try JSONDecoder().decode([String: String].self, from: AutomationPrivateFiles.read(controller.credentialURL(client)))
        try FileManager.default.removeItem(at: controller.credentialURL(client))
        await controller.connect(.codex)
        try expect(controller.clients.first?.id == client.id && controller.clients.first?.tokenDigest != client.tokenDigest,
                   "reconnect repairs a missing credential without duplicating the client")
        try expect(controller.clients.first?.permissions == [.libraryRead, .tabsRead], "credential repair preserves approved permissions")
        let oldAccess = await controller.handle(.init(id: UUID().uuidString, token: oldCredential["token"]!, tool: "get_status", arguments: [:]))
        try expect(oldAccess.error?.code == "unauthorized", "credential repair invalidates the old token")
        try AutomationPrivateFiles.write(Data("invalid".utf8), to: controller.credentialURL(client))
        await controller.connect(.codex)
        let repairedCredential = try JSONDecoder().decode([String: String].self, from: AutomationPrivateFiles.read(controller.credentialURL(client)))
        try expect(repairedCredential["client_id"] == client.id && controller.clients.first?.configuredAt != nil,
                   "reconnect repairs malformed credentials before claiming setup saved")
        let restored = AutomationController(model: model, directory: directory, browsing: FakeBrowser())
        try expect(restored.clients.first?.configuredAt != nil, "setup status survives restart")
        online = false
        let previousCalls = calls
        await controller.connect(.claudeDesktop)
        try expect(calls == previousCalls && controller.clients.count == 1, "unverified Pro cannot write client configuration")
        online = true; switchAccount = true
        await controller.connect(.claudeCode)
        try expect(controller.clients.count == 1 && controller.clients.first?.id == client.id, "account switch during setup revokes the newly created credential")
        try expect(controller.connectingClient == nil, "setup leaves no stuck progress state")
        print("Passed one-click setup checks: read-only defaults, persistence, retries, failure cleanup, Pro and account switching.")
    }

    private static func makeTabs() -> [AutomationTab] {
        (1...3).map { number in
            .init(tab: .init(browserID: "com.apple.Safari", browserName: "Safari", windowID: "fixture-window", tabID: "", index: number, title: "Fixture \(number)", url: "https://mcp-fixture.test/tab/\(number)"), processID: 1, launchedAt: Date(timeIntervalSince1970: 1), reference: "fixture-tab-\(number)")
        }
    }

    private final class FakeBrowser: AutomationBrowsing {
        var tabs: [AutomationTab] = []
        var snapshotCalls = 0, closeAttempts = 0, cancelledCloses = 0
        var closed: [String] = [], activated: [String] = [], opened: [URL] = []
        var activationStarted = false
        var onClose: ((AutomationTab) async throws -> Bool)?
        var onActivate: ((AutomationTab) async throws -> Bool)?
        var onHistory: (() async throws -> (entries: [BrowserHistoryEntry], warnings: [String]))?
        func snapshot() async throws -> (tabs: [AutomationTab], warnings: [String]) { snapshotCalls += 1; return (tabs, []) }
        func close(_ tab: AutomationTab) async throws -> Bool {
            closeAttempts += 1
            do {
                let result = try await onClose?(tab) ?? true
                if result { closed.append(tab.reference); tabs.removeAll { $0.reference == tab.reference } }
                return result
            } catch { if error is CancellationError { cancelledCloses += 1 }; throw error }
        }
        func activate(_ tab: AutomationTab) async throws -> Bool {
            let result = try await onActivate?(tab) ?? true
            if result { activated.append(tab.reference) }
            return result
        }
        func open(_ url: URL) -> Bool { opened.append(url); return true }
        func history() async throws -> (entries: [BrowserHistoryEntry], warnings: [String]) { try await onHistory?() ?? ([], []) }
    }

    nonisolated private static func socketSend(path: String, request: AutomationSocketRequest) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failed(errorDescription: "Could not create fixture socket.") }
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failed(errorDescription: "Fixture socket path too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw Failed(errorDescription: "Could not connect to fixture socket.") }
        var data = try JSONEncoder().encode(request); data.append(10)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard written > 0 else { throw Failed(errorDescription: "Could not send fixture socket request.") }; offset += written
            }
        }
        keep = true; return fd
    }
    nonisolated private static func socketRoundTrip(path: String, request: AutomationSocketRequest) throws -> AutomationSocketResponse {
        let fd = try socketSend(path: path, request: request)
        defer { Darwin.close(fd) }
        var response = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while response.count <= 8_388_608 {
            let received = recv(fd, &bytes, bytes.count, 0)
            guard received > 0 else { throw Failed(errorDescription: "Fixture socket closed without a complete response.") }
            response.append(contentsOf: bytes.prefix(received))
            if let end = response.firstIndex(of: 10) { return try JSONDecoder().decode(AutomationSocketResponse.self, from: response.prefix(upTo: end)) }
        }
        throw Failed(errorDescription: "Fixture socket response exceeded limit.")
    }
}
#endif
