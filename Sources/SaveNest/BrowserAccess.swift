import AppKit

/// Explain browser reads before any automatic discovery or user-requested capture.
/// This preference records the explanation, not macOS Automation authorization.
@MainActor
enum BrowserAccess {
    static var isExplained: Bool { UserDefaults.standard.bool(forKey: "browserAccessExplained") }

    static func confirm() -> Bool {
        if isExplained { return true }
        let alert = NSAlert()
        alert.messageText = "Connect your browsers to Savenest?"
        alert.informativeText = "Savenest reads open-tab titles and addresses so you can find and save pages. macOS may ask to control each supported browser; switching or closing tabs happens when you choose those actions.\n\nHistory search reads recent visits locally and can be paused. If your browser allows JavaScript from Apple Events, page text can also be read locally for search and Reader.\n\nUnsaved browser data stays on this Mac. Saved links and notes stay local unless you enable cloud backup or share them with a connected AI app. Usage counts contain none of this content.\n\nYou can skip access and paste a link instead."
        alert.addButton(withTitle: "Continue with browser access")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: "browserAccessExplained")
        return true
    }
}
