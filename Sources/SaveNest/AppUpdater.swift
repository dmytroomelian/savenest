import AppKit
import Combine
import Sparkle
import SwiftUI

/// Native Settings delegates to Electron when embedded; standalone releases use Sparkle.
@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    enum UpdateState: String {
        case idle, checking, downloading, downloaded, error, current
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var unavailableReason: String?
    @Published private(set) var updateState: UpdateState = .idle
    let usesElectronUpdater = ProcessInfo.processInfo.arguments.contains("--electron-bridge")
    var requestHostCheck: (() -> Void)?
    private var hostUpdatesEnabled = false
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Only the host can grant update capability. Never initialize Sparkle
        // inside its helper, including previews with simulated host status.
        if usesElectronUpdater {
            unavailableReason = AppLaunch.isPreview ? "Updates are disabled in Savenest Preview." : "Preparing update checks…"
            return
        }
        guard !AppLaunch.isPreview else {
            unavailableReason = "Updates are disabled in Savenest Preview."
            return
        }
        guard Bundle.main.bundleIdentifier == "app.savenest.mac",
              Bundle.main.object(forInfoDictionaryKey: "SaveNestUpdatesEnabled") as? Bool == true else {
            unavailableReason = "Updates are available in the installed release of Savenest."
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        if let updater = controller?.updater {
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        }
    }

    func start() {
        guard let controller else { return }
        do {
            try controller.updater.start()
        } catch {
            unavailableReason = "Updates couldn’t start. Reopen Savenest to try again."
            NSLog("Savenest updater failed to start: %@", error.localizedDescription)
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard !usesElectronUpdater, unavailableReason == nil else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    @discardableResult
    func receiveHostStatus(enabled: Bool, state: String) -> Bool {
        guard usesElectronUpdater, let value = UpdateState(rawValue: state) else { return false }
        hostUpdatesEnabled = enabled
        updateState = value
        unavailableReason = enabled ? nil : AppLaunch.isPreview
            ? "Updates are disabled in Savenest Preview."
            : "Updates are available in the installed release of Savenest."
        canCheckForUpdates = enabled && value != .checking && value != .downloading
        return true
    }

    var buttonTitle: String {
        guard usesElectronUpdater else { return "Check for Updates…" }
        switch updateState {
        case .checking: return "Checking…"
        case .downloading: return "Downloading…"
        case .downloaded: return "Install Update…"
        default: return "Check for Updates…"
        }
    }

    var statusMessage: String {
        if let unavailableReason { return unavailableReason }
        guard usesElectronUpdater else {
            return "Savenest checks for new versions in the background. You choose when to download and install them."
        }
        switch updateState {
        case .idle: return "Check when you’re ready. Available updates download after you start a check."
        case .checking: return "Checking for a new version of Savenest…"
        case .downloading: return "Downloading the update. You can keep using Savenest."
        case .downloaded: return "The update is ready. Install now or the next time you quit Savenest."
        case .error: return "Couldn’t check or download the update. Check your connection and try again."
        case .current: return "You’re using the latest available version of Savenest."
        }
    }

    var hostStatus: [String: Any] {
        ["enabled": hostUpdatesEnabled, "state": updateState.rawValue,
         "canCheckForUpdates": canCheckForUpdates, "buttonTitle": buttonTitle,
         "statusMessage": statusMessage]
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates, unavailableReason == nil else { return }
        if usesElectronUpdater {
            guard let requestHostCheck else { return }
            if updateState != .downloaded { receiveHostStatus(enabled: hostUpdatesEnabled, state: UpdateState.checking.rawValue) }
            requestHostCheck()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(sender)
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates && unavailableReason == nil
    }
}

struct AppUpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("APP UPDATES")
            HStack {
                Text("Savenest \(version)").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(updater.buttonTitle) { updater.checkForUpdates() }
                    .buttonStyle(QuietButton())
                    .disabled(!updater.canCheckForUpdates || updater.unavailableReason != nil)
            }
            if !updater.usesElectronUpdater {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticChecks($0) }
                ))
                .disabled(updater.unavailableReason != nil)
            }
            Text(updater.statusMessage)
                .font(.system(size: 11)).foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20).nestSurface()
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
