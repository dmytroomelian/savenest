import AppKit
import Combine
import SaveNestCore

struct SocialCapturePreferences: Codable, Equatable {
    var enabled = false
    var paused = false
    var platforms: Set<String> = []
    var allowLinkedInCopy = false
    var includeText = false
}

/// Owns consent and Pro access. Observers never own a library file or account token.
@MainActor
final class SocialCaptureController: ObservableObject {
    private unowned let model: AppModel
    private let browser = SocialBrowserCaptureObserver()
    private let slack = SocialSlackCaptureObserver()
    private let defaults: UserDefaults
    private let preferenceKey = "socialCapture.preferences.v1"
    private var timer: Timer?
    private var runningPlatforms: Set<String> = []
    private var runningUserID: String?
    private var lastRefresh = Date.distantPast
    private var refreshing = false
    private var clipboardTransaction = false
    private var configurationGeneration = 0
    @Published private(set) var preferences = SocialCapturePreferences()
    @Published private(set) var permissionGranted = false
    @Published private(set) var status = "Off. Your saves stay in their original apps."
    @Published private(set) var captureCount = 0
    @Published private(set) var lastCapture: String?
    @Published private(set) var changing = false

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        if !model.isPreview, let data = defaults.data(forKey: preferenceKey),
           let stored = try? JSONDecoder().decode(SocialCapturePreferences.self, from: data) {
            preferences = stored
            preferences.platforms.formIntersection(["slack", "linkedin", "x"])
        }
        browser.onAuthorizationCheck = { [weak self] in self?.authorized == true }
        slack.onAuthorizationCheck = { [weak self] in self?.authorized == true }
        browser.onCapture = { [weak self] capture in
            guard let self else { throw SocialSaveCaptureError("Capture stopped.") }
            try self.receive(capture)
        }
        slack.onCapture = browser.onCapture
        browser.onClipboardActivity = { [weak self] active in self?.setClipboardTransaction(active) }
        browser.onStatus = { [weak self] message in self?.observeStatus(message) }
        slack.onStatus = browser.onStatus
    }

    var available: Bool { SocialCaptureBuild.isAvailable && !model.isPreview && !AppRuntime.isPrivateBeta }
    var hasAccess: Bool { available && model.account.hasVerifiedSubscription }
    var isBusy: Bool { browser.isCapturing || changing }
    private var selectedPlatforms: Set<String> {
        var result = preferences.platforms
        if !preferences.allowLinkedInCopy { result.remove("linkedin") }
        return result
    }
    private var authorized: Bool {
        SocialCapturePolicy.mayObserve(enabled: preferences.enabled, paused: preferences.paused,
            verifiedPro: hasAccess, preview: !available, permission: SocialSlackCaptureObserver.trusted(),
            writableLibrary: model.canWriteLibrary,
            sameAccount: runningUserID != nil && runningUserID == model.account.account?.user.id)
    }
    var snapshot: [String: Any] {
        ["available": available, "enabled": preferences.enabled, "paused": preferences.paused,
         "hasAccess": hasAccess, "permissionGranted": permissionGranted,
         "status": status, "enabledCount": selectedPlatforms.count]
    }

    func start() {
        guard available, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
    }
    func stop() {
        configurationGeneration += 1
        timer?.invalidate(); timer = nil
        stopObservers(discard: true)
    }
    func accountDidChange() {
        if runningUserID != model.account.account?.user.id || !model.account.hasVerifiedSubscription {
            stopObservers(discard: true)
        }
        reconcile()
    }
    func setEnabled(_ enabled: Bool) async {
        guard available else { status = "Capture is disabled in this preview. No other apps are observed."; return }
        if !enabled { configurationGeneration += 1; preferences.enabled = false; persist(); stopObservers(discard: true); reconcile(); return }
        guard !changing else { return }
        changing = true
        let generation = configurationGeneration
        let accountSession = model.account.cloudSessionID
        defer { changing = false }
        if !hasAccess {
            lastRefresh = Date()
            _ = await model.account.refresh()
        }
        guard generation == configurationGeneration, accountSession == model.account.cloudSessionID else { return }
        guard hasAccess else { status = "Save from other apps requires active Pro. Open Account & Pro to continue."; return }
        preferences.enabled = true; preferences.paused = false
        persist(); reconcile()
    }
    func setPaused(_ value: Bool) { update { $0.paused = value } }
    func setPlatform(_ platform: String, enabled: Bool) {
        guard ["slack", "linkedin", "x"].contains(platform) else { return }
        update { if enabled { $0.platforms.insert(platform) } else { $0.platforms.remove(platform) } }
    }
    func setLinkedInCopy(_ value: Bool) { update { $0.allowLinkedInCopy = value } }
    func setIncludeText(_ value: Bool) { update { $0.includeText = value } }
    private func update(_ change: (inout SocialCapturePreferences) -> Void) {
        guard available else { return }
        configurationGeneration += 1
        stopObservers(discard: true)
        change(&preferences); persist(); reconcile()
    }
    private func persist() {
        guard available, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: preferenceKey)
    }
    func requestPermission() {
        guard available else { return }
        _ = SocialSlackCaptureObserver.trusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func refreshAccess() async {
        guard available, !refreshing else { return }
        refreshing = true; lastRefresh = Date()
        _ = await model.account.refresh()
        refreshing = false; reconcile()
    }
    private func reconcile() {
        guard available else {
            status = model.isPreview ? "Preview only. No apps are observed or saved." : "Available in the official Pro-enabled Savenest app."
            return
        }
        let trusted = SocialSlackCaptureObserver.trusted()
        if trusted != permissionGranted { permissionGranted = trusted }
        if preferences.enabled, model.account.hasLogin, !refreshing, Date().timeIntervalSince(lastRefresh) >= 60 {
            lastRefresh = Date()
            Task { [weak self] in await self?.refreshAccess() }
        }
        let reason: String?
        if !preferences.enabled { reason = "Off. Your saves stay in their original apps." }
        else if preferences.paused { reason = "Paused. No apps are being observed." }
        else if !hasAccess { reason = "Paused until Pro access can be verified. Manual saving still works." }
        else if !model.canWriteLibrary { reason = "Paused because your library needs attention." }
        else if !permissionGranted { reason = "Enable Accessibility for Savenest to detect saves in other apps." }
        else if selectedPlatforms.isEmpty { reason = "Choose an app below to begin." }
        else { reason = nil }
        if let reason { stopObservers(discard: true); if status != reason { status = reason }; return }
        if runningPlatforms != selectedPlatforms || runningUserID != model.account.account?.user.id {
            stopObservers(discard: true)
            runningPlatforms = selectedPlatforms; runningUserID = model.account.account?.user.id
            browser.enabledPlatforms = selectedPlatforms.intersection(["linkedin", "x"])
            if !browser.enabledPlatforms.isEmpty { browser.start() }
            if selectedPlatforms.contains("slack") { slack.start() }
            status = "Ready. Save a post or message in an enabled app while it is in front."
        }
    }
    private func stopObservers(discard: Bool) {
        browser.stop(); slack.stop()
        if discard { browser.discardPending(); slack.discardPending() }
        runningPlatforms = []; runningUserID = nil
        // The observer retains its bounded clipboard cleanup after capture stops.
        // Its completion callback releases clipboard-offer suppression.
    }
    private func setClipboardTransaction(_ value: Bool) {
        guard value != clipboardTransaction else { return }
        clipboardTransaction = value
        if value { model.clipboard.stop(); model.dismissClipboardNotice?() }
        else if model.clipboardEnabled && available { model.clipboard.start() }
    }
    var suppressesClipboardOffers: Bool { clipboardTransaction }
    private func observeStatus(_ message: String) {
        // Never surface raw post text or diagnostic trees in product status/analytics.
        let lower = message.lowercased()
        if lower.contains("pending") || lower.contains("failed") || lower.contains("timed out")
            || lower.contains("cancelled") || lower.contains("ownership") {
            status = message
        }
    }
    private func receive(_ value: SocialSaveCapture) throws {
        guard authorized, selectedPlatforms.contains(value.platform) else { throw SocialSaveCaptureError("Capture is paused.") }
        let capture = try value.validated()
        guard model.saveSocialCapture(capture, includeText: preferences.includeText) else {
            throw SocialSaveCaptureError("Couldn’t save to your library. Capture will retry while enabled.")
        }
        captureCount += 1
        let platform = ["slack": "Slack", "linkedin": "LinkedIn", "x": "X"][capture.platform] ?? "the app"
        lastCapture = "Saved from \(platform) at \(Date().formatted(date: .omitted, time: .shortened))."
        status = lastCapture!
    }
}
