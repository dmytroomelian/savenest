#if DEBUG
import Foundation
import CoreFoundation
import Darwin

enum AutomationClientInstallerChecks {
    private struct Failed: LocalizedError { let errorDescription: String? }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failed(errorDescription: "Connection installer check failed: " + message) }
    }
    private static func reject(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }
        throw Failed(errorDescription: "Connection installer should reject " + message)
    }
    private static func rejectAsync(_ action: () async throws -> Void, _ message: String) async throws {
        do { try await action() } catch { return }
        throw Failed(errorDescription: "Connection installer should reject " + message)
    }

    static func run() async throws {
        let root = URL(fileURLWithPath: "/tmp/savenest-installer-" + UUID().uuidString, isDirectory: true)
        try InstallerFiles.prepareDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("App 'quoted' $()/bin", isDirectory: true)
        try InstallerFiles.prepareDirectory(bin)
        let executable = bin.appendingPathComponent("savenest-mcp")
        try InstallerFiles.write(Data("#!/bin/sh\nexit 0\n".utf8), to: executable, mode: 0o700)
        let credentials = root.appendingPathComponent("private-credentials", isDirectory: true)
        try InstallerFiles.prepareDirectory(credentials)
        let firstCredential = credentials.appendingPathComponent("first.json"), secondCredential = credentials.appendingPathComponent("second.json")
        try InstallerFiles.write(Data("{\"token\":\"synthetic-do-not-copy\"}".utf8), to: firstCredential, mode: 0o600)
        try InstallerFiles.write(Data("{}".utf8), to: secondCredential, mode: 0o600)

        for kind in AutomationClientKind.allCases {
            let locations = AutomationClientInstaller.Locations(home: root.appendingPathComponent(kind.rawValue))
            let file = locations.file(for: kind)
            try InstallerFiles.prepareDirectory(file.deletingLastPathComponent())
            let original: Data = kind == .codex
                ? Data("model = \"gpt-6\"\n[features]\nweb_search_request = true\n[mcp_servers.other]\ncommand = \"/usr/bin/true\"\nargs = []\n".utf8)
                : Data("{\"enabled\":true,\"count\":1,\"preferences\":{\"theme\":\"dark\"},\"mcpServers\":{\"other\":{\"command\":\"/usr/bin/true\",\"args\":[]}}}".utf8)
            try InstallerFiles.write(original, to: file, mode: 0o640)
            let message = try await AutomationClientInstaller.install(kind, executable: executable, credential: firstCredential, locations: locations)
            try expect(message.contains("Setup saved") && message.contains("restart") && !message.contains("Connected"), "setup message does not claim a live connection")
            let installed = try InstallerFiles.read(file)
            try expect(installed.mode == 0o640, "existing config permissions survive")
            let text = String(decoding: installed.data!, as: UTF8.self)
            try expect(!text.contains("synthetic-do-not-copy"), "client config never contains credential contents")
            if kind == .codex {
                try expect(text.hasPrefix(String(decoding: original, as: UTF8.self)), "TOML leaves unrelated configuration byte-for-byte intact")
                try expect(!text.contains("\\/"), "TOML paths never use invalid JSON slash escapes")
                try expect(text.contains("[mcp_servers.savenest]"), "Codex server table is installed")
            } else {
                let object = try JSONSerialization.jsonObject(with: installed.data!) as! [String: Any]
                try expect(CFGetTypeID(object["enabled"]! as CFTypeRef) == CFBooleanGetTypeID(), "JSON boolean remains a boolean")
                try expect(CFGetTypeID(object["count"]! as CFTypeRef) != CFBooleanGetTypeID(), "JSON number does not become a boolean")
                try expect((object["preferences"] as? [String: String])?["theme"] == "dark", "unrelated app settings survive")
                let servers = object["mcpServers"] as! [String: [String: Any]], ours = servers["savenest"]!
                try expect(servers["other"]?["command"] as? String == "/usr/bin/true", "unrelated MCP entry survives")
                try expect(ours["command"] as? String == executable.path && ours["args"] as? [String] == ["--credential-file", firstCredential.path], "paths containing quotes and shell syntax remain literal")
                if kind == .claudeCode { try expect(ours["type"] as? String == "stdio", "Claude Code uses the documented stdio entry") }
            }
            let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".\(file.lastPathComponent).savenest-backup-") }
            try expect(backups.count == 1, "setup keeps one private original backup")
            let backup = try InstallerFiles.read(backups[0])
            try expect(backup.data == original && backup.mode == 0o600, "backup preserves the original bytes privately")
            _ = try await AutomationClientInstaller.install(kind, executable: executable, credential: secondCredential, locations: locations)
            let reconnected = String(decoding: try InstallerFiles.read(file).data!, as: UTF8.self)
            // JSON escaping varies, so parse its args; TOML fallback uses literal slashes.
            if kind == .codex {
                try expect(reconnected.contains(secondCredential.path) && !reconnected.contains(firstCredential.path), "Codex reconnect replaces only its old credential path")
                try expect(reconnected.components(separatedBy: "[mcp_servers.savenest]").count == 2, "Codex reconnect does not duplicate the table")
            } else {
                let object = try JSONSerialization.jsonObject(with: try InstallerFiles.read(file).data!) as! [String: Any]
                let ours = (object["mcpServers"] as! [String: [String: Any]])["savenest"]!
                try expect(ours["args"] as? [String] == ["--credential-file", secondCredential.path], "JSON reconnect uses the new credential")
            }
        }

        let jsonCollision = Data("{\"mcpServers\":{\"savenest\":{\"command\":\"/some/other-server\",\"args\":[]}}}".utf8)
        try reject({ _ = try AutomationClientInstaller.mergeJSON(jsonCollision, kind: .claudeDesktop, executable: executable, credential: firstCredential) }, "an unrelated savenest entry")
        try reject({ _ = try AutomationClientInstaller.mergeJSON(Data("{broken".utf8), kind: .claudeCode, executable: executable, credential: firstCredential) }, "malformed JSON")
        try reject({ _ = try AutomationClientInstaller.mergeJSON(Data("{\"mcpServers\":[]}".utf8), kind: .claudeCode, executable: executable, credential: firstCredential) }, "a non-object MCP section")
        for text in ["instructions = \"\"\"\n[mcp_servers.savenest]\n\"\"\"\n", "[mcp_servers.other]\nargs = [\n\"one\",\n]\n", "mcp_servers = { other = {} }\n", "[mcp_servers.savenest]\ncommand = \"/another/program\"\nargs = []\n"] {
            try reject({ _ = try AutomationClientInstaller.mergeCodex(Data(text.utf8), executable: executable, credential: firstCredential) }, "ambiguous, multiline, or unrelated TOML")
        }

        let conflictFile = root.appendingPathComponent("race.json")
        try InstallerFiles.write(Data("original".utf8), to: conflictFile, mode: 0o600)
        let snapshot = try InstallerFiles.read(conflictFile)
        try InstallerFiles.write(Data("concurrent edit".utf8), to: conflictFile, mode: 0o600)
        try reject({ try InstallerFiles.commit(Data("our edit".utf8), to: conflictFile, replacing: snapshot) }, "concurrent external edits")
        try expect(try InstallerFiles.read(conflictFile).data == Data("concurrent edit".utf8), "conflicting commit leaves the newer content intact")
        let beforeStaging = try InstallerFiles.read(conflictFile)
        try reject({
            try InstallerFiles.write(Data("staged replacement".utf8), to: conflictFile, mode: 0o600, expected: beforeStaging, afterStaging: {
                try InstallerFiles.write(Data("changed during staging".utf8), to: conflictFile, mode: 0o600)
            })
        }, "an external write during replacement staging")
        try expect(try InstallerFiles.read(conflictFile).data == Data("changed during staging".utf8), "final pre-rename check preserves an edit made during staging")

        let symlink = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: conflictFile)
        try reject({ _ = try InstallerFiles.read(symlink) }, "symlinked config")
        let fresh = AutomationClientInstaller.Locations(home: root.appendingPathComponent("fresh"))
        _ = try await AutomationClientInstaller.install(.claudeDesktop, executable: executable, credential: firstCredential, locations: fresh)
        try expect(try InstallerFiles.read(fresh.file(for: .claudeDesktop)).mode == 0o600, "new configuration is private")

        let failingCLI = root.appendingPathComponent("failing-codex")
        try InstallerFiles.write(Data("#!/bin/sh\nexit 7\n".utf8), to: failingCLI, mode: 0o700)
        let failed = AutomationClientInstaller.Locations(home: root.appendingPathComponent("failed-cli"), codexCLI: failingCLI)
        try InstallerFiles.prepareDirectory(failed.codexDirectory)
        let original = Data("model = \"gpt-6\"\n".utf8)
        try InstallerFiles.write(original, to: failed.file(for: .codex), mode: 0o600)
        try await rejectAsync({ _ = try await AutomationClientInstaller.install(.codex, executable: executable, credential: firstCredential, locations: failed) }, "CLI failure")
        try expect(try InstallerFiles.read(failed.file(for: .codex)).data == original, "CLI failure leaves live fixture config unchanged")

        let slowCLI = root.appendingPathComponent("slow-codex"), ready = root.appendingPathComponent("slow-started")
        let quotedReady = "'" + ready.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try InstallerFiles.write(Data(("#!/bin/sh\ntrap '' TERM\nprintf ready > " + quotedReady + "\nwhile :; do sleep 1; done\n").utf8), to: slowCLI, mode: 0o700)
        let slow = AutomationClientInstaller.Locations(home: root.appendingPathComponent("cancelled-cli"), codexCLI: slowCLI)
        try InstallerFiles.prepareDirectory(slow.codexDirectory)
        try InstallerFiles.write(original, to: slow.file(for: .codex), mode: 0o600)
        let cancelled = Task { try await AutomationClientInstaller.install(.codex, executable: executable, credential: firstCredential, locations: slow) }
        for _ in 0..<2_000 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let cancellationStart = Date(); cancelled.cancel()
        try await rejectAsync({ _ = try await cancelled.value }, "cancelled CLI setup")
        try expect(Date().timeIntervalSince(cancellationStart) < 5, "cancellation forcibly stops an uncooperative setup helper")
        try expect(try InstallerFiles.read(slow.file(for: .codex)).data == original, "cancelled setup does not write client settings")

        if let cli = AutomationClientInstaller.findCodexCLI(home: FileManager.default.homeDirectoryForCurrentUser) {
            let realCLI = AutomationClientInstaller.Locations(home: root.appendingPathComponent("official-cli"), codexCLI: cli)
            try InstallerFiles.prepareDirectory(realCLI.codexDirectory)
            let source = "model = \"gpt-6\"\n# Preserve this comment.\n[mcp_servers.other]\ncommand = \"/usr/bin/true\"\nargs = [\n  \"one\",\n  \"two\",\n]\n"
            try InstallerFiles.write(Data(source.utf8), to: realCLI.file(for: .codex), mode: 0o600)
            _ = try await AutomationClientInstaller.install(.codex, executable: executable, credential: firstCredential, locations: realCLI)
            let final = String(decoding: try InstallerFiles.read(realCLI.file(for: .codex)).data!, as: UTF8.self)
            try expect(final.contains("model = \"gpt-6\"") && final.contains("# Preserve this comment.") && final.contains("[mcp_servers.other]") && final.contains("[mcp_servers.savenest]"), "official CLI handles complex TOML and preserves unrelated settings")
            try expect(final.contains("tool_timeout_sec = 180"), "official CLI path gives new connections a 180-second timeout")
            var customized = final.replacingOccurrences(of: "enabled = true", with: "enabled = false")
                .replacingOccurrences(of: "tool_timeout_sec = 180", with: "tool_timeout_sec = 75")
            customized += "enabled_tools = [\"get_status\", \"search_links\"]\n"
            customized += "[mcp_servers.other.env]\nMULTILINE = \"\"\"\n[mcp_servers.savenest]\nThis is string content, not a table.\n\"\"\"\n"
            try InstallerFiles.write(Data(customized.utf8), to: realCLI.file(for: .codex), mode: 0o600)
            _ = try await AutomationClientInstaller.install(.codex, executable: executable, credential: secondCredential, locations: realCLI)
            let restored = String(decoding: try InstallerFiles.read(realCLI.file(for: .codex)).data!, as: UTF8.self)
            try expect(restored.contains("enabled = true") && !restored.contains("enabled = false"), "reconnecting explicitly enables Codex's SaveNest entry")
            try expect(restored.contains("enabled_tools = [\"get_status\", \"search_links\"]") && restored.contains("tool_timeout_sec = 75"), "reconnecting preserves the user's tool allowlist and existing timeout")
            try expect(restored.contains("# Preserve this comment.") && restored.contains("This is string content, not a table."), "surgical update preserves comments and multiline strings")
            try expect(restored.contains(secondCredential.path) && !restored.contains(firstCredential.path), "official CLI reconnect updates only the credential path")
            print("Passed official Codex CLI installation against disposable settings.")
        }
        print("Passed client installer checks: config preservation, ownership, quoted paths, JSON types, reconnects, backups, conflicts, private files, and CLI failures.")
    }
}
#endif
