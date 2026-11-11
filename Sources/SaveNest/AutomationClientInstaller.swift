import Foundation
import Darwin

enum AutomationClientKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claudeDesktop = "Claude Desktop"
    case claudeCode = "Claude Code"
    var id: String { rawValue }
    var title: String { rawValue }
    var detail: String {
        switch self {
        case .codex: "Find and organize links while you work."
        case .claudeDesktop: "Bring your saved links into Claude."
        case .claudeCode: "Use SaveNest from your coding sessions."
        }
    }
    var symbol: String {
        switch self { case .codex: "terminal"; case .claudeDesktop: "sparkle"; case .claudeCode: "chevron.left.forwardslash.chevron.right" }
    }
}

/// Installs only a SaveNest-owned stdio entry. Credentials remain in SaveNest's
/// private file; client configuration receives its path, never the token itself.
enum AutomationClientInstaller {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Locations: Sendable {
        let home: URL
        let codexDirectory: URL
        let codexCLI: URL?
        init(home: URL, codexDirectory: URL? = nil, codexCLI: URL? = nil) {
            self.home = home; self.codexDirectory = codexDirectory ?? home.appendingPathComponent(".codex")
            self.codexCLI = codexCLI
        }
        func file(for kind: AutomationClientKind) -> URL {
            switch kind {
            case .codex: codexDirectory.appendingPathComponent("config.toml")
            case .claudeDesktop: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .claudeCode: home.appendingPathComponent(".claude.json")
            }
        }
    }

    static func install(_ kind: AutomationClientKind, executable: URL, credential: URL) async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        if kind == .claudeCode, let override = env["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            throw Failure(message: "Claude Code uses a custom settings folder. Open Claude Code with its usual settings, then try connecting from SaveNest again.")
        }
        let override = env["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        let locations = Locations(home: home, codexDirectory: override, codexCLI: findCodexCLI(home: home))
        return try await install(kind, executable: executable, credential: credential, locations: locations)
    }

    static func install(_ kind: AutomationClientKind, executable: URL, credential: URL, locations: Locations) async throws -> String {
        let cancellation = InstallerCancellation()
        let work = Task.detached(priority: .userInitiated) {
            guard executable.isFileURL, executable.path.hasPrefix("/"), executable.lastPathComponent == "savenest-mcp",
                  FileManager.default.isExecutableFile(atPath: executable.path), credential.isFileURL, credential.path.hasPrefix("/") else {
                throw Failure(message: "The SaveNest connection helper is unavailable. Update SaveNest and try again.")
            }
            let file = locations.file(for: kind)
            try InstallerFiles.prepareDirectory(file.deletingLastPathComponent())
            let lock = try InstallerFiles.lock(file)
            defer { flock(lock, LOCK_UN); Darwin.close(lock) }
            let original = try InstallerFiles.read(file)
            let next: Data
            if kind == .codex {
                if let cli = locations.codexCLI {
                    next = try stageCodex(cli: cli, original: original.data, executable: executable, credential: credential, cancellation: cancellation)
                } else {
                    next = try mergeCodex(original.data, executable: executable, credential: credential)
                }
            } else {
                next = try mergeJSON(original.data, kind: kind, executable: executable, credential: credential)
            }
            try Task.checkCancellation()
            try InstallerFiles.commit(next, to: file, replacing: original)
            return "Setup saved. Open or restart \(kind.title) to finish connecting."
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel(); cancellation.cancel() })
    }

    static func findCodexCLI(home: URL) -> URL? {
        // Prefer the desktop app's bundled CLI. Finder-launched apps usually have
        // a minimal PATH, so also check the usual signed app and package locations.
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var candidates: [URL] = []
        for root in roots {
            for name in ["ChatGPT.app", "Codex.app"] {
                let resources = root.appendingPathComponent(name + "/Contents/Resources")
                candidates += [resources.appendingPathComponent("codex-cli/bin/codex"), resources.appendingPathComponent("codex")]
            }
        }
        candidates += [home.appendingPathComponent(".local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where path.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: String(path)).appendingPathComponent("codex"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func isOwned(command: Any?, arguments: Any?, credential: URL) -> Bool {
        guard let command = command as? String, command.hasPrefix("/"), URL(fileURLWithPath: command).lastPathComponent == "savenest-mcp",
              let args = arguments as? [String], args.count == 2, args[0] == "--credential-file", args[1].hasPrefix("/") else { return false }
        return URL(fileURLWithPath: args[1]).deletingLastPathComponent().standardizedFileURL == credential.deletingLastPathComponent().standardizedFileURL
    }
    private static func collision() -> Failure { Failure(message: "This app already has another connection named savenest. Rename that connection in the app, then try again.") }

    static func mergeJSON(_ previous: Data?, kind: AutomationClientKind, executable: URL, credential: URL) throws -> Data {
        var document: [String: Any]
        if let previous {
            guard let value = try? JSONSerialization.jsonObject(with: previous), let object = value as? [String: Any] else {
                throw Failure(message: "This app's settings are not valid JSON. Its settings were left unchanged.")
            }
            document = object
        } else { document = [:] }
        var servers: [String: Any] = [:]
        if let existing = document["mcpServers"] {
            guard let object = existing as? [String: Any] else { throw Failure(message: "This app's connection settings have an unsupported format. They were left unchanged.") }
            servers = object
        }
        var entry: [String: Any] = [:]
        if let old = servers["savenest"] {
            guard let object = old as? [String: Any], isOwned(command: object["command"], arguments: object["args"], credential: credential), object["url"] == nil else { throw collision() }
            entry = object
        }
        entry["command"] = executable.path
        entry["args"] = ["--credential-file", credential.path]
        if kind == .claudeCode { entry["type"] = "stdio" }
        servers["savenest"] = entry; document["mcpServers"] = servers
        guard JSONSerialization.isValidJSONObject(document) else { throw Failure(message: "This app's settings could not be updated safely.") }
        var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10); return data
    }

    private static func stageCodex(cli: URL, original: Data?, executable: URL, credential: URL, cancellation: InstallerCancellation) throws -> Data {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("savenest-codex-" + UUID().uuidString, isDirectory: true)
        try InstallerFiles.prepareDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent("config.toml")
        if let original { try InstallerFiles.write(original, to: stagedFile, mode: 0o600) }
        // CODEX_HOME is the CLI's supported configuration location. Override it
        // only for this subprocess, so the CLI cannot modify the live config.
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = staging.path
        let before = try run(cli, arguments: ["mcp", "list", "--json"], environment: environment, cancellation: cancellation)
        guard let servers = try? JSONSerialization.jsonObject(with: before) as? [[String: Any]] else {
            throw Failure(message: "Codex settings could not be checked. Open Codex, resolve any settings error, and try again.")
        }
        if let existing = servers.first(where: { $0["name"] as? String == "savenest" }) {
            let transport = existing["transport"] as? [String: Any] ?? existing
            guard isOwned(command: transport["command"], arguments: transport["args"], credential: credential) else { throw collision() }
        }
        // The CLI's add command rewrites unrelated comments and replaces the
        // whole server entry, dropping tool allowlists. Use its parser to validate
        // a surgical edit instead; preserve all unedited bytes and server options.
        let candidate = try editValidatedCodex(original, executable: executable, credential: credential, existing: servers.contains { $0["name"] as? String == "savenest" })
        try InstallerFiles.write(candidate, to: stagedFile, mode: 0o600)
        let after = try run(cli, arguments: ["mcp", "list", "--json"], environment: environment, cancellation: cancellation)
        guard let installed = try? JSONSerialization.jsonObject(with: after) as? [[String: Any]],
              let entry = installed.first(where: { $0["name"] as? String == "savenest" }) else { throw Failure(message: "Codex did not save the connection. Its original settings were left unchanged.") }
        let transport = entry["transport"] as? [String: Any] ?? entry
        guard transport["command"] as? String == executable.path, transport["args"] as? [String] == ["--credential-file", credential.path], entry["enabled"] as? Bool != false else {
            throw Failure(message: "Codex did not save the expected connection. Its original settings were left unchanged.")
        }
        let otherBefore = servers.filter { $0["name"] as? String != "savenest" }
        let otherAfter = installed.filter { $0["name"] as? String != "savenest" }
        guard NSArray(array: otherBefore).isEqual(to: otherAfter) else { throw Failure(message: "Codex changed another connection during setup. Its original settings were left unchanged.") }
        guard let result = try InstallerFiles.read(stagedFile).data else { throw Failure(message: "Codex did not write its settings.") }
        return result
    }

    private static func tomlQuote(_ value: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
    private static func editValidatedCodex(_ previous: Data?, executable: URL, credential: URL, existing: Bool) throws -> Data {
        guard let text = String(data: previous ?? Data(), encoding: .utf8) else { throw unsupportedTOML() }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var desired = ["command": tomlQuote(executable.path), "args": "[\(tomlQuote("--credential-file")), \(tomlQuote(credential.path))]", "enabled": "true", "tool_timeout_sec": "180"]
        let order = ["command", "args", "enabled", "tool_timeout_sec"]
        if !existing {
            let separator = text.isEmpty || text.hasSuffix("\n") ? "" : newline
            return Data((text + separator + newline + "[mcp_servers.savenest]" + newline + order.map { "\($0) = \(desired[$0]!)" }.joined(separator: newline) + newline).utf8)
        }
        let source = text as NSString
        var table: [String] = [], insertion: Int?, edits: [(NSRange, String)] = [], found = Set<String>()
        for range in try statements(text) {
            let statement = source.substring(with: range), trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") {
                let header = try uncomment(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
                let array = header.hasPrefix("[[")
                guard header.hasSuffix(array ? "]]" : "]") else { throw unsupportedTOML() }
                let count = array ? 2 : 1
                table = try keyPath(String(header.dropFirst(count).dropLast(count)))
                if table == ["mcp_servers", "savenest"] {
                    guard !array, insertion == nil else { throw unsupportedTOML() }
                    insertion = range.location + range.length
                }
                continue
            }
            guard let equal = try separator(trimmed, character: "=") else { throw unsupportedTOML() }
            let keys = try keyPath(String(trimmed[..<equal])), full = table + keys
            if full.count == 3, full.prefix(2) == ["mcp_servers", "savenest"], let name = full.last, desired[name] != nil {
                guard table == ["mcp_servers", "savenest"], keys.count == 1, found.insert(name).inserted else { throw unsupportedTOML() }
                if name == "tool_timeout_sec" { desired.removeValue(forKey: name); continue }
                edits.append((range, "\(name) = \(desired[name]!)" + newline)); desired.removeValue(forKey: name)
            }
        }
        guard let insertion else { throw unsupportedTOML() }
        let additions = order.compactMap { key in desired[key].map { "\(key) = \($0)" + newline } }.joined()
        if !additions.isEmpty { edits.append((NSRange(location: insertion, length: 0), additions)) }
        let result = NSMutableString(string: text)
        // Apply replacements before insertions at the same offset.
        for edit in edits.sorted(by: { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location > $1.0.location }) { result.replaceCharacters(in: edit.0, with: edit.1) }
        return Data((result as String).utf8)
    }

    /// Locates complete statements without interpreting values. The official CLI
    /// validates both documents; this scanner only protects multiline boundaries.
    private static func statements(_ text: String) throws -> [NSRange] {
        let units = Array(text.utf16)
        var result: [NSRange] = [], start = 0, index = 0, quote = 0, depth = 0, comment = false, escape = false
        while index < units.count {
            let c = units[index]
            if comment {
                if c == 10 { comment = false; if depth == 0 { result.append(NSRange(location: start, length: index + 1 - start)); start = index + 1 } }
            } else if quote != 0 {
                if (quote == 1 || quote == 3), c == 92, !escape { escape = true; index += 1; continue }
                let mark: UInt16 = (quote == 1 || quote == 3) ? 34 : 39
                if c == mark, !escape {
                    if quote <= 2 { quote = 0 }
                    else if index + 2 < units.count, units[index + 1] == mark, units[index + 2] == mark { quote = 0; index += 2 }
                }
                escape = false
            } else if c == 35 { comment = true }
            else if c == 34 || c == 39 {
                if index + 2 < units.count, units[index + 1] == c, units[index + 2] == c { quote = c == 34 ? 3 : 4; index += 2 }
                else { quote = c == 34 ? 1 : 2 }
            } else if c == 91 || c == 123 { depth += 1 }
            else if c == 93 || c == 125 { depth -= 1; guard depth >= 0 else { throw unsupportedTOML() } }
            else if c == 10, depth == 0 { result.append(NSRange(location: start, length: index + 1 - start)); start = index + 1 }
            index += 1
        }
        guard quote == 0, depth == 0 else { throw unsupportedTOML() }
        if start < units.count { result.append(NSRange(location: start, length: units.count - start)) }
        return result
    }

    /// Conservative fallback for standard single-line TOML. Complex documents
    /// require Codex's own parser; this function never guesses table boundaries.
    static func mergeCodex(_ previous: Data?, executable: URL, credential: URL) throws -> Data {
        guard let text = String(data: previous ?? Data(), encoding: .utf8) else { throw unsupportedTOML() }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline), table: [String] = []
        var assignments: [String: (line: Int, value: Any)] = [:], sectionLine: Int?, sectionEnd: Int?
        var allKeys = Set<String>(), tables = Set<String>()
        for (index, raw) in lines.enumerated() {
            let line = try uncomment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else { throw unsupportedTOML() }
                let path = try keyPath(String(line.dropFirst().dropLast()))
                let key = path.joined(separator: "\u{0}")
                guard tables.insert(key).inserted else { throw unsupportedTOML() }
                if table == ["mcp_servers", "savenest"], sectionEnd == nil { sectionEnd = index }
                table = path
                if path == ["mcp_servers", "savenest"] { sectionLine = index }
                continue
            }
            guard let equal = try separator(line, character: "=") else { throw unsupportedTOML() }
            let key = try keyPath(String(line[..<equal]))
            let full = table + key
            let fullKey = full.joined(separator: "\u{0}")
            guard allKeys.insert(fullKey).inserted else { throw unsupportedTOML() }
            // Dotted or inline definitions may seal the namespace. Never append
            // another table when its meaning requires a complete TOML parser.
            if table != ["mcp_servers", "savenest"], full.starts(with: ["mcp_servers", "savenest"]) { throw unsupportedTOML() }
            if full == ["mcp_servers"] { throw unsupportedTOML() }
            let value = try simpleValue(String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces))
            if table == ["mcp_servers", "savenest"] {
                guard key.count == 1 else { throw unsupportedTOML() }
                assignments[key[0]] = (index, value)
            }
        }
        func quote(_ value: String) -> String { tomlQuote(value) }
        let replacements = ["command": quote(executable.path), "args": "[\(quote("--credential-file")), \(quote(credential.path))]", "enabled": "true", "tool_timeout_sec": "180"]
        if sectionLine != nil {
            guard isOwned(command: assignments["command"]?.value, arguments: assignments["args"]?.value, credential: credential), assignments["url"] == nil else { throw collision() }
            var missing: [String] = []
            for key in ["command", "args", "enabled", "tool_timeout_sec"] {
                if key == "tool_timeout_sec", assignments[key] != nil { continue }
                let line = "\(key) = \(replacements[key]!)"
                if let old = assignments[key] { lines[old.line] = line } else { missing.append(line) }
            }
            lines.insert(contentsOf: missing, at: sectionEnd ?? lines.count)
        } else {
            if lines.last?.isEmpty != true { lines.append("") }
            lines.append("[mcp_servers.savenest]")
            lines += ["command", "args", "enabled", "tool_timeout_sec"].map { "\($0) = \(replacements[$0]!)" }
        }
        if lines.last?.isEmpty != true { lines.append("") }
        return Data(lines.joined(separator: newline).utf8)
    }
    private static func unsupportedTOML() -> Failure { Failure(message: "Codex settings need its own setup helper. Open or update Codex, then try Connect again. Existing settings were left unchanged.") }
    private static func uncomment(_ text: String) throws -> String {
        if text.contains("\"\"\"") || text.contains("'''") { throw unsupportedTOML() }
        var quote: Character?, escape = false
        for index in text.indices {
            let c = text[index]
            if let active = quote {
                if active == "\"" && c == "\\" && !escape { escape = true; continue }
                if c == active && !escape { quote = nil }; escape = false
            } else if c == "#" { return String(text[..<index]) }
            else if c == "\"" || c == "'" { quote = c }
        }
        guard quote == nil else { throw unsupportedTOML() }; return text
    }
    private static func separator(_ text: String, character: Character) throws -> String.Index? {
        var quote: Character?, escape = false
        for index in text.indices {
            let c = text[index]
            if let active = quote {
                if active == "\"" && c == "\\" && !escape { escape = true; continue }
                if c == active && !escape { quote = nil }; escape = false
            } else if c == character { return index }
            else if c == "\"" || c == "'" { quote = c }
        }
        guard quote == nil else { throw unsupportedTOML() }; return nil
    }
    private static func keyPath(_ raw: String) throws -> [String] {
        var remainder = raw.trimmingCharacters(in: .whitespaces), parts: [String] = []
        while !remainder.isEmpty {
            let dot = try separator(remainder, character: ".")
            let part = String(dot.map { remainder[..<$0] } ?? remainder[...]).trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("\"") || part.hasPrefix("'") {
                guard let value = try simpleValue(part) as? String else { throw unsupportedTOML() }; parts.append(value)
            } else {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw unsupportedTOML() }
                parts.append(part)
            }
            guard let dot else { break }
            remainder = String(remainder[remainder.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else { throw unsupportedTOML() }
        }
        guard !parts.isEmpty else { throw unsupportedTOML() }; return parts
    }
    private static func simpleValue(_ text: String) throws -> Any {
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2, !text.dropFirst().dropLast().contains("'") { return String(text.dropFirst().dropLast()) }
        if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), !(value is NSNull), !(value is [String: Any]) { return value }
        throw unsupportedTOML()
    }

    private final class InstallerCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run(); self.process = process
        }
        func finished(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            if self.process === process { self.process = nil }
        }
        func cancel() {
            lock.lock(); cancelled = true; let running = process; lock.unlock()
            guard let running, running.isRunning else { return }
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
    private static func run(_ executable: URL, arguments: [String], environment: [String: String], cancellation: InstallerCancellation) throws -> Data {
        let process = Process()
        guard let staging = environment["CODEX_HOME"] else { throw Failure(message: "Codex setup could not create temporary settings.") }
        let outputURL = URL(fileURLWithPath: staging).appendingPathComponent(".setup-output-" + UUID().uuidString)
        let fd = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure(message: "Codex setup could not create private temporary storage.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { Darwin.close(fd); unlink(outputURL.path) }
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        // A private regular file avoids pipe deadlocks, including inherited pipe
        // writers in a helper subprocess. No diagnostics reach the UI or logs.
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try cancellation.start(process) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure(message: "Codex's setup helper could not start. Open or update Codex and try again.") }
        let timeout = DispatchWorkItem { cancellation.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        process.waitUntilExit(); timeout.cancel(); cancellation.finished(process)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw Failure(message: "Codex could not update its settings. Open Codex, resolve any settings error, and try again. Existing settings were left unchanged.") }
        return try InstallerFiles.read(outputURL).data ?? Data()
    }
}

enum InstallerFiles {
    struct Snapshot { let data: Data?; let mode: mode_t; let inode: ino_t; let device: dev_t }
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw failure("The app's settings folder is not a regular folder owned by you.") }
    }
    static func lock(_ file: URL) throws -> Int32 {
        let path = file.deletingLastPathComponent().appendingPathComponent(".savenest-connect.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Could not lock the app's settings for setup.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw failure("Another connection setup is running. Try again when it finishes.")
        }
        return fd
    }
    static func read(_ file: URL) throws -> Snapshot {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return .init(data: nil, mode: 0o600, inode: 0, device: 0) }
        guard fd >= 0 else { throw failure("This app's settings are linked or unreadable. They were left unchanged.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16 * 1024 * 1024 else { throw failure("This app's settings could not be read safely. They were left unchanged.") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        return .init(data: data, mode: info.st_mode & 0o777, inode: info.st_ino, device: info.st_dev)
    }
    static func commit(_ data: Data, to file: URL, replacing original: Snapshot) throws {
        let current = try read(file)
        guard current.data == original.data, current.inode == original.inode, current.device == original.device else { throw failure("This app changed its settings during setup. Try Connect again; no changes were applied.") }
        if current.data == data { return }
        if let previous = original.data {
            let backup = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).savenest-backup-\(UUID().uuidString)")
            try write(previous, to: backup, mode: 0o600)
        }
        // Recheck after writing the backup to avoid overwriting a concurrent edit.
        let checked = try read(file)
        guard checked.data == original.data, checked.inode == original.inode, checked.device == original.device else { throw failure("This app changed its settings during setup. Try Connect again; no changes were applied.") }
        try write(data, to: file, mode: original.mode, expected: original)
    }
    static func write(_ data: Data, to file: URL, mode: mode_t, expected: Snapshot? = nil, afterStaging: (() throws -> Void)? = nil) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".savenest-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Could not save the app's connection settings.") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw failure("Could not save the app's connection settings.") }; offset += count
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw failure("Could not save the app's connection settings.") }
        try afterStaging?()
        if let expected {
            let current = try read(file)
            guard current.data == expected.data, current.inode == expected.inode, current.device == expected.device else {
                throw failure("This app changed its settings during setup. Try Connect again; no changes were applied.")
            }
        }
        guard rename(temporary.path, file.path) == 0 else { throw failure("Could not save the app's connection settings.") }
    }
    private static func failure(_ message: String) -> AutomationClientInstaller.Failure { .init(message: message) }
}
