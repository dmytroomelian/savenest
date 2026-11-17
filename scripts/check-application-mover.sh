#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/savenest-mover-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/check.swift" <<'SWIFT'
import AppKit

@main
@MainActor
enum ApplicationMoverChecks {
    static func check(_ condition: Bool, _ message: String = "Fixture check failed") {
        precondition(condition, message)
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("savenest-install-fixture-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        try manager.createDirectory(at: applications, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("SaveNest 2.app")
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("new app".utf8).write(to: source.appendingPathComponent("fixture"))
        let quarantine = "0081;00000000;SaveNestInstallerTest;"
        let attribute = Process()
        attribute.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        attribute.arguments = ["-w", "com.apple.quarantine", quarantine, source.path]
        try attribute.run(); attribute.waitUntilExit()
        precondition(attribute.terminationStatus == 0)

        let installed = try ApplicationMover.install(source, applications: applications)
        precondition(installed.lastPathComponent == "SaveNest.app", "Repeated downloads must use the canonical name")
        precondition(manager.fileExists(atPath: source.path), "The source must remain available on a failed handoff")
        check(try String(contentsOf: installed.appendingPathComponent("fixture"), encoding: .utf8) == "new app")
        let readAttribute = Process()
        let output = Pipe()
        readAttribute.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        readAttribute.arguments = [installed.path]
        readAttribute.standardOutput = output
        try readAttribute.run(); readAttribute.waitUntilExit()
        precondition(readAttribute.terminationStatus == 0)
        let installedAttributes = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(!installedAttributes.split(separator: "\n").contains("com.apple.quarantine"), "New installation must not relaunch translocated")
        let sourceAttribute = Process()
        sourceAttribute.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        sourceAttribute.arguments = ["-p", "com.apple.quarantine", source.path]
        sourceAttribute.standardOutput = Pipe()
        try sourceAttribute.run(); sourceAttribute.waitUntilExit()
        precondition(sourceAttribute.terminationStatus == 0, "Source download must retain quarantine")

        try Data("existing app".utf8).write(to: installed.appendingPathComponent("fixture"))
        do {
            _ = try ApplicationMover.install(source, applications: applications)
            preconditionFailure("An existing installation must never be overwritten")
        } catch {
            check(try String(contentsOf: installed.appendingPathComponent("fixture"), encoding: .utf8) == "existing app")
        }
        check(try manager.contentsOfDirectory(atPath: applications.path) == ["SaveNest.app"], "Failed copies must not leave staging folders")
        let missingSource = root.appendingPathComponent("Missing.app")
        do {
            _ = try ApplicationMover.install(missingSource, applications: applications)
            preconditionFailure("Missing source must fail")
        } catch {
            check(try String(contentsOf: installed.appendingPathComponent("fixture"), encoding: .utf8) == "existing app")
        }
        check(try manager.contentsOfDirectory(atPath: applications.path) == ["SaveNest.app"])
        let libraryFolder = root.appendingPathComponent("Library")
        var session: LibrarySessionLock? = try LibrarySessionLock(folder: libraryFolder)
        withExtendedLifetime(session) {
            do {
                _ = try LibrarySessionLock(folder: libraryFolder)
                preconditionFailure("A second library writer must be rejected")
            } catch {
                precondition(error as? LibrarySessionLock.Failure == .busy)
            }
        }
        session = nil
        // A leftover lock file is normal. Only an actively held OS lock blocks launch.
        let nextSession = try LibrarySessionLock(folder: libraryFolder)
        withExtendedLifetime(nextSession) {}
        let blockedFolder = root.appendingPathComponent("BlockedLibrary")
        try manager.createDirectory(at: blockedFolder, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: blockedFolder.appendingPathComponent("library-session.lock"), withDestinationURL: source)
        do {
            _ = try LibrarySessionLock(folder: blockedFolder)
            preconditionFailure("An inaccessible lock must fail")
        } catch {
            precondition(error as? LibrarySessionLock.Failure != .busy, "Filesystem errors are not duplicate apps")
        }
        print("Application mover checks passed: canonical name, new-copy launch preparation, source preserved, no overwrite, clean failure.")
        print("Library lock checks passed: active writer blocked, stale file accepted, access failure distinguished.")
    }
}
SWIFT
swiftc -parse-as-library Sources/SaveNest/AppRuntime.swift Sources/SaveNest/ApplicationMover.swift Sources/SaveNest/LibrarySessionLock.swift "$work/check.swift" -o "$work/check"
"$work/check"
