import AppKit
import Darwin

@MainActor
enum ApplicationMover {
    private static let declinedKey = "declinedApplicationMove"

    /// Offers to install public builds that were launched from Downloads, a disk image,
    /// or another folder. Returns true when this process is handing off to the installed copy.
    static func offerMoveIfNeeded() -> Bool {
        guard shouldOfferMove else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move Savenest to Applications?"
        alert.informativeText = "Savenest can move itself to your Applications folder and reopen from there. This keeps the app and its updates in the usual place."
        alert.addButton(withTitle: "Move to Applications")
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
            let destination = try install(source)
            try clearQuarantine(at: destination)
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
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }

        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return applicationDirectories.allSatisfy { !source.isInside($0) }
    }

    private static var applicationDirectories: [URL] {
        let manager = FileManager.default
        return [FileManager.SearchPathDomainMask.localDomainMask, .userDomainMask, .systemDomainMask]
            .compactMap { manager.urls(for: .applicationDirectory, in: $0).first?.resolvingSymlinksInPath() }
    }

    private static func install(_ source: URL) throws -> URL {
        let manager = FileManager.default
        guard let applications = manager.urls(for: .applicationDirectory, in: .localDomainMask).first else {
            throw MoveError.applicationsFolderUnavailable
        }

        let destination = applications.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            let staging = applications.appendingPathComponent(".SaveNest-\(UUID().uuidString).install.app", isDirectory: true)
            do {
                try manager.copyItem(at: source, to: staging)
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
        } else {
            do {
                try manager.copyItem(at: source, to: destination)
            } catch {
                try? manager.removeItem(at: destination)
                throw error
            }
        }
        return destination
    }

    /// A programmatic copy keeps Gatekeeper's quarantine attribute. Clear it from
    /// the installed bundle so macOS launches that path instead of translocating it
    /// and offering to move it again.
    private static func clearQuarantine(at application: URL) throws {
        let errorCode = application.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 else { return 0 }
            return errno
        }
        guard errorCode == 0 || errorCode == ENOATTR else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: application.path]
            )
        }
    }

    private static func relaunch(_ application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", application.path]
        try process.run()
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Savenest couldn’t be moved"
        alert.informativeText = "You can keep using Savenest here, or move it to Applications in Finder.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    private enum MoveError: LocalizedError {
        case applicationsFolderUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationsFolderUnavailable:
                return "The Applications folder could not be found."
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
