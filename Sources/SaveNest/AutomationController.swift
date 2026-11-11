import AppKit
import CryptoKit
import Security
import SwiftUI
import SaveNestCore

enum AutomationPermission: String, Codable, CaseIterable, Identifiable {
    case libraryRead = "library_read", tabsRead = "tabs_read", historyRead = "history_read"
    case libraryEdit = "library_edit", openLinks = "open_links", removeLinks = "remove_links"
    case saveAndClose = "save_and_close", closeTabs = "close_tabs"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .libraryRead: "Read saved links and quick notes"
        case .tabsRead: "Read open tabs"
        case .historyRead: "Read recent browser history"
        case .libraryEdit: "Save and edit links"
        case .openLinks: "Open links and switch tabs"
        case .removeLinks: "Remove saved links"
        case .saveAndClose: "Save tabs, then close them"
        case .closeTabs: "Close tabs without saving"
        }
    }
}

struct AutomationClient: Codable, Identifiable {
    let id: String
    let name: String
    let userID: String
    var tokenDigest: String
    var permissions: Set<AutomationPermission>
    var configuredAt: Date? = nil
}

@MainActor
final class AutomationController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var clients: [AutomationClient] = []
    @Published private(set) var message: String?
    @Published private(set) var listening = false
    @Published private(set) var activity: [String] = []
    @Published private(set) var connectingClient: AutomationClientKind?
    @Published private(set) var activeClients: Set<String> = []
    private unowned let model: AppModel
    private let browsing: AutomationBrowsing
    let directory: URL
    var socketPath: String { directory.appendingPathComponent("mcp.sock").path }
    private let server = AutomationSocket()
    private struct Settings: Codable { let enabled: Bool; let clients: [AutomationClient] }
    private var settingsURL: URL { directory.appendingPathComponent("clients.json") }
    private var tabs: [String: AutomationTab] = [:]
    private var history: [String: BrowserHistoryEntry] = [:]
    private var running: [String: Task<[String: AutomationValue], Error>] = [:]
    private var pending: [String: (String, Task<[String: AutomationValue], Error>)] = [:]
    private var completed: [String: (String, Result<[String: AutomationValue], AutomationFailure>)] = [:]
    private struct Undo { let token: String; let client: String; let generation: UUID; let before: Library; let permission: AutomationPermission }
    private var undo: Undo?
    #if DEBUG
    var testUser: (() async throws -> String)?
    var testInstaller: ((AutomationClientKind, URL, URL) async throws -> String)?
    var testAdapterURL: URL?
    func hasRunningRequestForTesting(clientID: String, requestID: String) -> Bool { running[clientID + ":" + requestID] != nil }
    func startForTesting() throws {
        guard model.isPreview, testUser != nil else { throw AutomationFailure("test_only", "Requires sample preview and test verification.") }
        try persist(enabled: true, clients: clients); enabled = true; startServer()
        guard listening else { throw AutomationFailure("socket_failed", message ?? "Socket did not start.") }
    }
    #endif

    init(model: AppModel, directory: URL? = nil, browsing: AutomationBrowsing? = nil) {
        self.model = model; self.directory = directory ?? AppRuntime.supportDirectory.appendingPathComponent("AI", isDirectory: true)
        self.browsing = browsing ?? AutomationBrowser()
        guard !model.isPreview || directory != nil else { return }
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                let saved = try JSONDecoder().decode(Settings.self, from: AutomationPrivateFiles.read(settingsURL))
                enabled = saved.enabled; clients = saved.clients
            }
        } catch { message = "AI connection settings could not be read. Access is disabled." }
    }

    var adapterURL: URL? {
        #if DEBUG
        if model.isPreview, testInstaller != nil, let testAdapterURL { return testAdapterURL }
        #endif
        let bundle = Bundle.main.bundleURL
        let candidates = [bundle.appendingPathComponent("Contents/Resources/savenest-mcp"),
                          bundle.deletingLastPathComponent().appendingPathComponent("savenest-mcp")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func start() {
        guard enabled, !model.isPreview else { return }
        startServer()
    }
    private func startServer() {
        do {
            try AutomationPrivateFiles.directory(directory)
            try server.start(path: socketPath) { [weak self] request in
                guard let self else { return .init(id: request.id, error: .init(code: "unavailable", message: "Open SaveNest and try again.")) }
                let response = await self.handle(request)
                if response.error == nil, request.tool != "cancel", let client = try? self.authenticate(request.token) {
                    self.activeClients.insert(client.id)
                }
                return response
            }
            listening = true
        } catch { listening = false; message = error.localizedDescription }
    }
    func stop() {
        server.stop(); listening = false
        running.values.forEach { $0.cancel() }; running.removeAll()
        tabs.removeAll(); history.removeAll(); undo = nil
        activeClients.removeAll()
    }
    private func persist(enabled: Bool, clients: [AutomationClient]) throws {
        try AutomationPrivateFiles.directory(directory)
        try AutomationPrivateFiles.write(JSONEncoder().encode(Settings(enabled: enabled, clients: clients)), to: settingsURL)
    }
    func setEnabled(_ value: Bool) {
        guard !model.isPreview else { message = "AI connections are unavailable in the sample preview."; return }
        do { try changeEnabled(value) } catch { message = error.localizedDescription }
    }
    private func changeEnabled(_ value: Bool) throws {
        try persist(enabled: value, clients: clients); enabled = value
        if value { startServer() } else { stop() }
    }
    private func verifiedUser() async throws -> String {
        #if DEBUG
        if let testUser { return try await testUser() }
        #endif
        if !model.account.hasVerifiedSubscription { _ = await model.account.refresh() }
        guard model.account.hasVerifiedSubscription else {
            throw AutomationFailure("pro_required", "Sign in with active SaveNest Pro and verify your account online. Core local features remain available.")
        }
        guard let id = model.account.account?.user.id else { throw AutomationFailure("pro_required", "Sign in to SaveNest Pro.") }
        return id
    }
    func addClient(name: String) async {
        do {
            let user = try await verifiedUser()
            _ = try createClient(name: name, user: user)
            message = "Connection created."
        } catch { message = error.localizedDescription }
    }
    private func createClient(name: String, user: String) throws -> AutomationClient {
        guard clients.count < 20 else { throw AutomationFailure("client_limit", "Disconnect an unused app before adding another.") }
        try AutomationPrivateFiles.directory(directory)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AutomationFailure("credential_failed", "Could not create a connection credential.") }
        let token = Data(bytes).base64EncodedString(), id = UUID().uuidString
        let client = AutomationClient(id: id, name: String(name.prefix(80)), userID: user, tokenDigest: digest(token), permissions: [.libraryRead])
        let credential: [String: String] = ["client_id": id, "token": token, "socket_path": socketPath]
        let url = credentialURL(client)
        try AutomationPrivateFiles.write(JSONEncoder().encode(credential), to: url)
        do { try persist(enabled: enabled, clients: clients + [client]) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        clients.append(client)
        return client
    }
    private func repairCredentialIfNeeded(_ client: AutomationClient) throws -> AutomationClient {
        let url = credentialURL(client)
        let previous = try? AutomationPrivateFiles.read(url)
        if let previous, let value = try? JSONDecoder().decode([String: String].self, from: previous),
           value["client_id"] == client.id, value["socket_path"] == socketPath,
           let token = value["token"], digest(token) == client.tokenDigest { return client }
        guard let index = clients.firstIndex(where: { $0.id == client.id }) else {
            throw AutomationFailure("revoked", "This app was disconnected. Connect again.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AutomationFailure("credential_failed", "Could not repair this connection. Try again.")
        }
        let token = Data(bytes).base64EncodedString()
        var repaired = client; repaired.tokenDigest = digest(token); repaired.configuredAt = nil
        var next = clients; next[index] = repaired
        try AutomationPrivateFiles.write(JSONEncoder().encode(["client_id": client.id, "token": token, "socket_path": socketPath]), to: url)
        do { try persist(enabled: enabled, clients: next) }
        catch {
            if let previous { try? AutomationPrivateFiles.write(previous, to: url) }
            else { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        clients = next; activeClients.remove(client.id)
        for (key, task) in running where key.hasPrefix(client.id + ":") { task.cancel() }
        return repaired
    }
    func connection(for kind: AutomationClientKind) -> AutomationClient? {
        clients.first { $0.name == kind.rawValue && $0.userID == model.account.account?.user.id }
            ?? clients.first { $0.name == kind.rawValue }
    }
    func connect(_ kind: AutomationClientKind) async {
        guard connectingClient == nil else { return }
        #if DEBUG
        let testing = model.isPreview && testUser != nil && testInstaller != nil && testAdapterURL != nil
        #else
        let testing = false
        #endif
        guard !model.isPreview || testing else { message = "Connections are unavailable in this preview."; return }
        guard let executable = adapterURL else { message = "AI connections are coming soon with Pro."; return }
        connectingClient = kind; message = nil
        defer { connectingClient = nil }
        var created: AutomationClient?
        let wasEnabled = enabled
        do {
            let user = try await verifiedUser()
            let client: AutomationClient
            if let existing = clients.first(where: { $0.name == kind.rawValue && $0.userID == user }) { client = try repairCredentialIfNeeded(existing) }
            else { client = try createClient(name: kind.rawValue, user: user); created = client }
            if !enabled || !listening { try changeEnabled(true) }
            guard listening else { throw AutomationFailure("unavailable", "Could not start the connection. Try again.") }
            let result: String
            #if DEBUG
            if testing, let testInstaller { result = try await testInstaller(kind, executable, credentialURL(client)) }
            else { result = try await AutomationClientInstaller.install(kind, executable: executable, credential: credentialURL(client)) }
            #else
            result = try await AutomationClientInstaller.install(kind, executable: executable, credential: credentialURL(client))
            #endif
            guard try await verifiedUser() == user, enabled,
                  let index = clients.firstIndex(where: { $0.id == client.id }) else {
                throw AutomationFailure("account_changed", "Your account or connection changed. Connect again when ready.")
            }
            var next = clients; next[index].configuredAt = Date()
            try persist(enabled: enabled, clients: next); clients = next
            message = result
        } catch {
            if let created { revoke(created) }
            if !wasEnabled { try? changeEnabled(false) }
            message = error.localizedDescription
            if (error as? AutomationFailure)?.code == "pro_required" { model.showAccount?() }
        }
    }
    func setPermission(_ permission: AutomationPermission, allowed: Bool, clientID: String) {
        guard let index = clients.firstIndex(where: { $0.id == clientID }) else { return }
        var next = clients
        if allowed { next[index].permissions.insert(permission) } else { next[index].permissions.remove(permission) }
        do {
            try persist(enabled: enabled, clients: next); clients = next
            // Permission changes take effect at the next item boundary too.
            if !allowed { for (key, task) in running where key.hasPrefix(clientID + ":") { task.cancel() } }
        } catch { message = error.localizedDescription }
    }
    func revoke(_ client: AutomationClient) {
        let next = clients.filter { $0.id != client.id }
        do {
            try persist(enabled: enabled, clients: next); clients = next
            activeClients.remove(client.id)
            for (key, task) in running where key.hasPrefix(client.id + ":") { task.cancel() }
            try? FileManager.default.removeItem(at: credentialURL(client))
            if undo?.client == client.id { undo = nil }
            message = "Connection revoked. Its old setup no longer grants access."
        } catch { message = error.localizedDescription }
    }
    func credentialURL(_ client: AutomationClient) -> URL { directory.appendingPathComponent("\(client.id).json") }
    func configuration(_ client: AutomationClient, format: String) -> String? {
        guard let executable = adapterURL else { return nil }
        let args = ["--credential-file", credentialURL(client).path]
        func json(_ text: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try! encoder.encode(text), as: UTF8.self)
        }
        if format == "Codex" {
            return "[mcp_servers.savenest]\ncommand = \(json(executable.path))\nargs = [\(args.map(json).joined(separator: ", "))]\ntool_timeout_sec = 180\n"
        }
        if format == "Claude Code" {
            func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return "claude mcp add --scope user --transport stdio savenest -- " + ([executable.path] + args).map(quote).joined(separator: " ")
        }
        let value: [String: AutomationValue] = ["mcpServers": .object(["savenest": .object(["command": .string(executable.path), "args": .array(args.map(AutomationValue.string))])])]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
    func testConnection(_ client: AutomationClient) async {
        do {
            let data = try AutomationPrivateFiles.read(credentialURL(client))
            let credential = try JSONDecoder().decode([String: String].self, from: data)
            guard let token = credential["token"] else { throw AutomationFailure("credential_failed", "Recreate this connection.") }
            let response = await handle(.init(id: UUID().uuidString, token: token, tool: "get_status", arguments: [:]))
            message = response.error?.message ?? (response.result?["pro_verified"]?.bool == true ? "Credential accepted. Pro verified. Connect your AI client to test the complete connection." : "Credential accepted. Verify Pro online before using tools.")
        } catch { message = error.localizedDescription }
    }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func authenticate(_ token: String) throws -> AutomationClient {
        guard enabled else { throw AutomationFailure("disabled", "Enable AI connections in SaveNest Settings.") }
        let hash = digest(token)
        guard let client = clients.first(where: { $0.tokenDigest == hash }) else { throw AutomationFailure("unauthorized", "This connection was revoked or its credential is invalid.") }
        return client
    }
    private func authorize(_ client: AutomationClient, permissions: Set<AutomationPermission>) async throws {
        try Task.checkCancellation()
        guard enabled, let current = clients.first(where: { $0.id == client.id }), current.permissions.isSuperset(of: permissions) else {
            throw AutomationFailure("permission_denied", "Grant this action in SaveNest Settings → AI connections.")
        }
        let user = try await verifiedUser()
        try Task.checkCancellation()
        guard user == client.userID, enabled, clients.contains(where: { $0.id == client.id && $0.permissions.isSuperset(of: permissions) }) else {
            throw AutomationFailure("permission_denied", "This connection belongs to another account or its permissions changed. Reconnect in SaveNest Settings.")
        }
    }
    func handle(_ request: AutomationSocketRequest) async -> AutomationSocketResponse {
        do {
            let client = try authenticate(request.token)
            try validateArguments(request.tool, arguments: request.arguments)
            if request.tool == "cancel" {
                if let id = request.arguments["request_id"]?.string { running[client.id + ":" + id]?.cancel() }
                return .init(id: request.id, result: ["cancelled": .bool(true)])
            }
            if request.tool == "get_status" {
                let verified = (try? await verifiedUser()) == client.userID
                let current = try authenticate(request.token)
                return .init(id: request.id, result: ["connected": .bool(true), "pro_verified": .bool(verified),
                    "permissions": .array(current.permissions.map { .string($0.rawValue) }.sorted { ($0.string ?? "") < ($1.string ?? "") }),
                    "browsers": .array(Browser.supported.map { .object(["name": .string($0.name), "running": .bool(!NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty)]) }),
                    "guidance": .string(verified ? "SaveNest must remain running. Browser actions may need macOS Automation permission." : "Verify active SaveNest Pro online. Core local features remain available.")])
            }
            let readOnly = ["search_links", "get_links"].contains(request.tool)
            var cacheKey: String?, signature = ""
            if !readOnly {
                guard let id = request.arguments["request_id"]?.string, !id.isEmpty, id.count <= 128 else { throw AutomationFailure("invalid_arguments", "Mutations require a request_id of 1–128 characters.") }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                signature = digest(request.tool + String(decoding: try encoder.encode(request.arguments), as: UTF8.self))
                cacheKey = client.id + ":" + id
                try await authorize(client, permissions: requiredPermissions(request.tool))
                if let cached = completed[cacheKey!] {
                    guard cached.0 == signature else { throw AutomationFailure("request_conflict", "Use a new request_id for different arguments.") }
                    return .init(id: request.id, result: try cached.1.get())
                }
                if let existing = pending[cacheKey!] {
                    guard existing.0 == signature else { throw AutomationFailure("request_conflict", "Use a new request_id for different arguments.") }
                    let alias = client.id + ":" + request.id
                    guard running[alias] == nil else { throw AutomationFailure("request_conflict", "This transport request is already running.") }
                    running[alias] = existing.1
                    defer { running.removeValue(forKey: alias) }
                    let value = try await withTaskCancellationHandler(operation: { try await existing.1.value }, onCancel: { existing.1.cancel() })
                    return .init(id: request.id, result: value)
                }
                guard completed.count + pending.count < 4096 else { throw AutomationFailure("session_capacity", "Restart SaveNest before starting more mutations.") }
            }
            let work = Task { try await self.perform(request.tool, arguments: request.arguments, client: client) }
            let key = client.id + ":" + request.id
            guard running[key] == nil else { work.cancel(); throw AutomationFailure("request_conflict", "This transport request is already running.") }
            running[key] = work
            if let cacheKey { pending[cacheKey] = (signature, work) }
            let outcome = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
            running.removeValue(forKey: key)
            let result = outcome.mapError { error -> AutomationFailure in
                if let failure = error as? AutomationFailure { return failure }
                if error is CancellationError { return AutomationFailure("cancelled", "Cancelled. Completed changes remain; inspect current state before another action.") }
                return AutomationFailure("operation_failed", "SaveNest could not complete this action. Check the app and try again.")
            }
            if let cacheKey { pending.removeValue(forKey: cacheKey); completed[cacheKey] = (signature, result) }
            let summary: String
            switch result { case .success(let value): summary = "\(request.tool): \(value["completed"]?.int ?? value["total"]?.int ?? 0) completed or found"
            case .failure(let failure): summary = "\(request.tool): \(failure.code)" }
            activity.insert("\(client.name) · \(summary)", at: 0); activity = Array(activity.prefix(30))
            return .init(id: request.id, result: try result.get())
        } catch {
            let failure = error as? AutomationFailure ?? AutomationFailure("cancelled", "Request cancelled.")
            return .init(id: request.id, error: .init(code: failure.code, message: failure.message))
        }
    }
    private func requiredPermissions(_ tool: String) throws -> Set<AutomationPermission> {
        switch tool {
        case "get_links": return [.libraryRead]
        case "search_links": return []
        case "add_links", "update_links": return [.libraryRead, .libraryEdit]
        case "remove_links": return [.libraryRead, .removeLinks]
        case "open_links": return [.openLinks]
        case "save_tabs": return [.tabsRead, .libraryRead, .libraryEdit]
        case "close_tabs": return [.tabsRead, .closeTabs]
        case "undo_change": return [.libraryRead]
        default: throw AutomationFailure("unknown_tool", "This tool is not supported.")
        }
    }
    private func validateArguments(_ tool: String, arguments: [String: AutomationValue]) throws {
        let allowed: Set<String>
        switch tool {
        case "get_status": allowed = []
        case "cancel": allowed = ["request_id"]
        case "search_links": allowed = ["query", "sources", "filters", "limit", "cursor"]
        case "get_links": allowed = ["ids"]
        case "add_links", "update_links", "remove_links": allowed = ["request_id", "items"]
        case "open_links": allowed = ["request_id", "targets"]
        case "save_tabs": allowed = ["request_id", "tabs", "note", "tags", "collection", "close_after"]
        case "close_tabs": allowed = ["request_id", "tabs"]
        case "undo_change": allowed = ["request_id", "operation_token"]
        default: throw AutomationFailure("unknown_tool", "This tool is not supported.")
        }
        guard Set(arguments.keys).isSubset(of: allowed) else {
            throw AutomationFailure("invalid_arguments", "Unrecognized tool arguments. Use the documented fields; no action was taken.")
        }
    }
    private func perform(_ tool: String, arguments: [String: AutomationValue], client: AutomationClient) async throws -> [String: AutomationValue] {
        try await authorize(client, permissions: requiredPermissions(tool))
        if tool == "search_links" { return try await search(arguments, client: client) }
        if tool == "undo_change" {
            guard let undo, undo.token == arguments["operation_token"]?.string, undo.client == client.id,
                  undo.generation == model.automationGeneration else { throw AutomationFailure("undo_expired", "Another library change or restart expired this undo token.") }
            try await authorize(client, permissions: [undo.permission, .libraryRead])
            guard undo.generation == model.automationGeneration else { throw AutomationFailure("undo_expired", "The library changed during verification.") }
            guard model.automationCommit(undo.before) else { throw AutomationFailure("write_failed", "Could not save the undo. The library is unchanged.") }
            self.undo = nil
            return ["completed": .number(1)]
        }
        if ["get_links", "add_links", "update_links", "remove_links"].contains(tool) {
            let before = model.library
            let value = try AutomationLibrary.execute(tool: tool, arguments: arguments, library: before)
            var result = value.result
            if value.changed {
                guard model.automationCommit(value.library) else { throw AutomationFailure("write_failed", "Could not save changes. No library changes were committed.") }
                result["operation_token"] = .string(rememberUndo(before, client: client, permission: tool == "remove_links" ? .removeLinks : .libraryEdit))
            }
            return result
        }
        return try await browserAction(tool, arguments: arguments, client: client)
    }
    private func rememberUndo(_ before: Library, client: AutomationClient, permission: AutomationPermission) -> String {
        let token = UUID().uuidString
        undo = Undo(token: token, client: client.id, generation: model.automationGeneration, before: before, permission: permission)
        return token
    }
    private func search(_ arguments: [String: AutomationValue], client: AutomationClient) async throws -> [String: AutomationValue] {
        let sources: [String]
        if let raw = arguments["sources"] {
            guard let array = raw.array, !array.isEmpty, array.count <= 3, array.allSatisfy({ ["saved", "open", "history"].contains($0.string ?? "") }) else { throw AutomationFailure("invalid_arguments", "Choose saved, open, or history sources.") }
            sources = Array(Set(array.compactMap(\.string)))
        } else { sources = ["saved"] }
        var permissions = Set<AutomationPermission>()
        if sources.contains("saved") { permissions.insert(.libraryRead) }
        if sources.contains("open") { permissions.insert(.tabsRead) }
        if sources.contains("history") { permissions.insert(.historyRead) }
        try await authorize(client, permissions: permissions)
        var records: [[String: AutomationValue]] = [], warnings: [String] = []
        if sources.contains("open") {
            let snapshot = try await browsing.snapshot(); warnings += snapshot.warnings
            for target in snapshot.tabs {
                tabs[target.reference] = target
                records.append(["id": .string("tab:" + target.reference), "source": .string("open"), "tab_ref": .string(target.reference),
                    "url": .string(target.tab.url), "title": .string(target.tab.title), "browser": .string(target.tab.browserName)])
            }
            if tabs.count > 20_000 { tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.reference, $0) }) }
        }
        if sources.contains("history") {
            guard model.tabSearch.historyEnabled else { throw AutomationFailure("history_disabled", "Enable browser history in SaveNest before sharing it with this client.") }
            let scan = try await browsing.history(); warnings += scan.warnings
            guard model.tabSearch.historyEnabled else { throw AutomationFailure("history_disabled", "History sharing was disabled during this request.") }
            for entry in scan.entries {
                let ref = digest(entry.id); history[ref] = entry
                records.append(["id": .string("history:" + ref), "source": .string("history"), "history_ref": .string(ref), "url": .string(entry.url),
                    "title": .string(entry.title), "browser": .string(entry.browser), "last_visited": .string(ISO8601DateFormatter().string(from: entry.lastVisited))])
            }
            if history.count > 60_000 { history = Dictionary(scan.entries.map { (digest($0.id), $0) }, uniquingKeysWith: { first, _ in first }) }
        }
        try await authorize(client, permissions: permissions)
        if sources.contains("saved") { records += model.library.links.map { AutomationLibrary.record($0) } }
        var result = try AutomationLibrary.search(records: records, arguments: arguments)
        result["warnings"] = .array(warnings.map(AutomationValue.string))
        return result
    }
    private func browserAction(_ tool: String, arguments: [String: AutomationValue], client: AutomationClient) async throws -> [String: AutomationValue] {
        let field = tool == "open_links" ? "targets" : "tabs"
        guard let values = arguments[field]?.array, !values.isEmpty, values.count <= 20, values.allSatisfy({ $0.object != nil }) else {
            throw AutomationFailure("invalid_arguments", "Select between 1 and 20 explicit targets.")
        }
        if let raw = arguments["close_after"], raw.bool == nil { throw AutomationFailure("invalid_arguments", "close_after must be true or false.") }
        let closeAfter = arguments["close_after"]?.bool == true
        if closeAfter { try await authorize(client, permissions: [.saveAndClose]) }
        var currentTabs: [AutomationTab] = []
        if tool == "save_tabs" || (tool == "open_links" && clients.first(where: { $0.id == client.id })?.permissions.contains(.tabsRead) == true) {
            try await authorize(client, permissions: [.tabsRead])
            currentTabs = try await browsing.snapshot().tabs
        }
        // Descending positions keep the original Safari indices valid while closing siblings.
        let ordered = values.enumerated().sorted { lhs, rhs in
            guard tool != "open_links", let a = lhs.element.object?["tab_ref"]?.string.flatMap({ tabs[$0] }),
                  let b = rhs.element.object?["tab_ref"]?.string.flatMap({ tabs[$0] }) else { return lhs.offset < rhs.offset }
            if a.tab.browserID != b.tab.browserID { return a.tab.browserID < b.tab.browserID }
            if a.tab.windowID != b.tab.windowID { return a.tab.windowID < b.tab.windowID }
            return a.tab.index > b.tab.index
        }
        var results: [[String: AutomationValue]] = [], seen = Set<String>(), operationToken: String?
        var batchBefore: Library?, lastGeneration: UUID?
        for (index, value) in ordered {
            var item: [String: AutomationValue] = ["index": .number(Double(index))]
            do {
                try await authorize(client, permissions: requiredPermissions(tool))
                if closeAfter { try await authorize(client, permissions: [.saveAndClose]) }
                let target = value.object!
                if tool == "open_links", let id = target["id"]?.string {
                    try await authorize(client, permissions: [.libraryRead])
                    guard target.count == 1, let link = model.library.links.first(where: { $0.id.uuidString == id }), let url = Library.validatedURL(link.url) else { throw AutomationFailure("not_found", "Saved link not found.") }
                    guard seen.insert("saved:" + id).inserted else { throw AutomationFailure("duplicate_target", "Target selected twice.") }
                    // Inspect tabs only when the client also has tab-reading permission.
                    var activated = false
                    if clients.first(where: { $0.id == client.id })?.permissions.contains(.tabsRead) == true {
                        try await authorize(client, permissions: [.libraryRead, .tabsRead, .openLinks])
                        if let match = currentTabs.first(where: { Library.identity($0.tab.url) == Library.identity(link.url) }) { activated = try await browsing.activate(match) }
                    }
                    if !activated {
                        try await authorize(client, permissions: [.libraryRead, .openLinks])
                        guard browsing.open(url) else { throw AutomationFailure("open_failed", "The browser did not open this link.") }
                    }
                    item["status"] = .string("completed")
                } else if tool == "open_links", let ref = target["history_ref"]?.string {
                    try await authorize(client, permissions: [.historyRead])
                    guard model.tabSearch.historyEnabled, target.count == 1, let entry = history[ref], let url = Library.validatedURL(entry.url) else { throw AutomationFailure("not_found", "Search history again before opening this link.") }
                    guard seen.insert("history:" + ref).inserted else { throw AutomationFailure("duplicate_target", "Target selected twice.") }
                    var activated = false
                    if clients.first(where: { $0.id == client.id })?.permissions.contains(.tabsRead) == true,
                       let match = currentTabs.first(where: { Library.identity($0.tab.url) == Library.identity(entry.url) }) {
                        try await authorize(client, permissions: [.historyRead, .tabsRead, .openLinks])
                        activated = try await browsing.activate(match)
                    }
                    if !activated {
                        try await authorize(client, permissions: [.historyRead, .openLinks])
                        guard model.tabSearch.historyEnabled else { throw AutomationFailure("history_disabled", "History sharing was disabled.") }
                        guard browsing.open(url) else { throw AutomationFailure("open_failed", "The browser did not open this link.") }
                    }
                    item["status"] = .string("completed")
                } else {
                    try await authorize(client, permissions: [.tabsRead])
                    guard target.count == 1, let ref = target["tab_ref"]?.string, let tab = tabs[ref] else { throw AutomationFailure("stale_tab", "Search open tabs again before taking this action.") }
                    item["tab_ref"] = .string(ref)
                    guard seen.insert(ref).inserted else { throw AutomationFailure("duplicate_target", "Tab selected twice.") }
                    if tool == "open_links" {
                        guard try await browsing.activate(tab) else { throw AutomationFailure("stale_tab", "The tab changed or is unavailable.") }
                    } else if tool == "save_tabs" {
                        // Fresh enumeration prevents saving the wrong page from an old reference.
                        guard currentTabs.contains(where: { $0.reference == ref }) else { throw AutomationFailure("stale_tab", "The tab changed. Search again.") }
                        try await authorize(client, permissions: [.tabsRead, .libraryRead, .libraryEdit])
                        var fields: [String: AutomationValue] = ["url": .string(tab.tab.url), "title": .string(tab.tab.title)]
                        for key in ["note", "tags", "collection"] { fields[key] = arguments[key] }
                        let before = model.library
                        let save = try AutomationLibrary.execute(tool: "add_links", arguments: ["items": .array([.object(fields)])], library: before)
                        guard save.result["failed"]?.int == 0 else { throw AutomationFailure("save_failed", "Could not save this tab. Check the supplied note, tags, or collection.") }
                        if save.changed {
                            if lastGeneration != model.automationGeneration { batchBefore = before }
                            guard model.automationCommit(save.library) else { throw AutomationFailure("write_failed", "Could not save this tab. It stayed open.") }
                            lastGeneration = model.automationGeneration
                            operationToken = rememberUndo(batchBefore ?? before, client: client, permission: .libraryEdit)
                        }
                        item["saved"] = .bool(true)
                        if closeAfter {
                            try await authorize(client, permissions: [.saveAndClose, .tabsRead])
                            guard try await browsing.close(tab) else { throw AutomationFailure("close_failed", "Saved, but the changed, ambiguous, or protected tab stayed open.") }
                            item["closed"] = .bool(true)
                        }
                    } else {
                        guard try await browsing.close(tab) else { throw AutomationFailure("close_failed", "The changed, ambiguous, or protected tab stayed open.") }
                        item["closed"] = .bool(true)
                    }
                    item["status"] = .string("completed")
                }
            } catch {
                let failure = error as? AutomationFailure ?? AutomationFailure(error is CancellationError ? "cancelled" : "browser_unavailable", "The browser action did not complete. Inspect current tabs before trying again.")
                item["status"] = .string("failed"); item["code"] = .string(failure.code); item["message"] = .string(failure.message)
            }
            results.append(item)
        }
        results.sort { ($0["index"]?.int ?? 0) < ($1["index"]?.int ?? 0) }
        var result: [String: AutomationValue] = ["items": .array(results.map(AutomationValue.object)),
            "completed": .number(Double(results.filter { $0["status"]?.string == "completed" }.count)),
            "skipped": .number(0), "failed": .number(Double(results.filter { $0["status"]?.string == "failed" }.count))]
        if let operationToken { result["operation_token"] = .string(operationToken) }
        return result
    }
}
