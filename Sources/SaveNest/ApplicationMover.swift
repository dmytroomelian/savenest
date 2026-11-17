import AppKit
import Darwin

@MainActor
enum ApplicationMover {
    private static let declinedKey = "declinedApplicationMove"
    private static let installedLaunchArgument = "--savenest-installed"

    /// Offers to install public builds that were launched from Downloads, a disk image,
    /// or another folder. Returns true when this process is handing off to the installed copy.
    static func offerMoveIfNeeded() -> Bool {
        guard shouldOfferMove else { return false }

        if let installed = installedApplication {
            return offerInstalledApplication(installed)
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install Savenest in Applications?"
        alert.informativeText = "Savenest will copy itself to Applications and open from there. You can also keep using this download for now."
        alert.addButton(withTitle: "Install & Open")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: declinedKey)
            }
            return false
        }

        do {
            let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
            guard let applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first else {
                throw MoveError.applicationsFolderUnavailable
            }
            let destination = try install(source, applications: applications)
            try relaunch(destination)
            NSApp.terminate(nil)
            return true
        } catch {
            presentFailure(error)
            return false
        }
    }

    private static var shouldOfferMove: Bool {
        guard Bundle.main.bundleIdentifier == "app.savenest.mac",
              Bundle.main.object(forInfoDictionaryKey: "SaveNestUpdatesEnabled") as? Bool == true,
              Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              !UserDefaults.standard.bool(forKey: declinedKey),
              !ProcessInfo.processInfo.arguments.contains(installedLaunchArgument) else { return false }

        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return applicationDirectories.allSatisfy { !source.isInside($0) }
    }

    private static var applicationDirectories: [URL] {
        let manager = FileManager.default
        return [FileManager.SearchPathDomainMask.localDomainMask, .userDomainMask, .systemDomainMask]
            .compactMap { manager.urls(for: .applicationDirectory, in: $0).first?.resolvingSymlinksInPath() }
    }

    private static var installedApplication: URL? {
        applicationDirectories
            .map { $0.appendingPathComponent("SaveNest.app", isDirectory: true) }
            .first { url in
                guard let identifier = Bundle(url: url)?.bundleIdentifier else { return false }
                return ["app.savenest.mac", "app.savenest.electron"].contains(identifier)
            }
    }

    private static func offerInstalledApplication(_ application: URL) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open Savenest from Applications?"
        alert.informativeText = "Savenest is already in Applications. Open that copy to continue. To update it, choose Check for Updates from its Savenest menu."
        alert.addButton(withTitle: "Open Installed Savenest")
        alert.addButton(withTitle: "Continue Here")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try relaunch(application)
            NSApp.terminate(nil)
            return true
        } catch {
            presentFailure(error)
            return false
        }
    }

    // Keep the destination independent of Finder's repeated-download name, e.g. SaveNest 2.app.
    // Stage first, then atomically publish without replacing an existing or concurrently installed app.
    static func install(_ source: URL, applications: URL) throws -> URL {
        let manager = FileManager.default
        let destination = applications.appendingPathComponent("SaveNest.app", isDirectory: true)
        let staging = applications.appendingPathComponent(".SaveNest-\(UUID().uuidString).install", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let stagedApplication = staging.appendingPathComponent("SaveNest.app", isDirectory: true)
        try manager.copyItem(at: source, to: stagedApplication)
        try clearQuarantine(at: stagedApplication)
        guard renamex_np(stagedApplication.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
        return destination
    }

    /// This running release has already been approved by macOS. Preserve the
    /// existing self-install behavior on its new copy so it opens at the writable
    /// Applications path, not a read-only translocation. Never alter the source
    /// download or a previously installed app.
    private static func clearQuarantine(at application: URL) throws {
        let errorCode = application.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 else { return 0 }
            return errno
        }
        guard errorCode == 0 || errorCode == ENOATTR else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: [NSFilePathErrorKey: application.path])
        }
    }

    private static func relaunch(_ application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let installedIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.bundleURL?.resolvingSymlinksInPath() == application.resolvingSymlinksInPath()
        }
        // A fresh handoff needs a new instance: LaunchServices could otherwise reuse this
        // Downloads copy. Reuse an already running installed copy rather than duplicating it.
        // The argument also avoids a repeated setup prompt during cross-host handoff.
        process.arguments = (installedIsRunning ? [] : ["-n"]) + ["-a", application.path, "--args", installedLaunchArgument]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MoveError.launchFailed }
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Savenest couldn’t finish setup"
        alert.informativeText = "You can keep using Savenest here, or move it to Applications in Finder.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    private enum MoveError: LocalizedError {
        case applicationsFolderUnavailable
        case launchFailed

        var errorDescription: String? {
            switch self {
            case .applicationsFolderUnavailable:
                return "The Applications folder could not be found."
            case .launchFailed:
                return "Open Savenest from Applications in Finder. macOS may need you to approve opening it."
            }
        }
    }
}

private extension URL {
    func isInside(_ directory: URL) -> Bool {
        let filePath = standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }
}
