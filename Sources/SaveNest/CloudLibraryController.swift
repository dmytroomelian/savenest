import AppKit
import Combine
import SaveNestCore

@MainActor
final class CloudLibraryController: ObservableObject {
    enum Activity { case idle, checking, uploading, restoring }
    @Published private(set) var enabled = false
    @Published private(set) var status: CloudStatus?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var message: String?
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var recoveryFile: URL?
    @Published private(set) var needsLocalReview = false
    private weak var model: AppModel?
    private var identity: String?
    private var sessionID: UUID?
    private var generation = UUID()
    private var uploadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pending: (snapshot: CloudLibrarySnapshot, fingerprint: String)?
    private var lastFingerprint: String?
    private let defaults: UserDefaults
    private let reviewKey = "savenest.cloud.local-library-review-required"
    let deviceID: UUID
    var isBusy: Bool { activity != .idle }
    var snapshots: [CloudSnapshotSummary] { status?.snapshots ?? [] }
    var hasAccount: Bool { model?.account.account != nil }

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        if let value = defaults.string(forKey: "savenest.cloud.device"), let id = UUID(uuidString: value) { deviceID = id }
        else {
            deviceID = UUID()
            if !model.isPreview { defaults.set(deviceID.uuidString, forKey: "savenest.cloud.device") }
        }
        if !model.isPreview {
            if !model.cloudLibraryExistedAtStartup || !model.canWriteLibrary {
                defaults.set(true, forKey: reviewKey)
                for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("savenest.cloud.enabled.") {
                    defaults.set(false, forKey: key)
                }
            }
            needsLocalReview = defaults.bool(forKey: reviewKey)
        }
    }
    private func preferenceKey(_ user: String) -> String { "savenest.cloud.enabled.\(user)" }
    private func isCurrent(_ user: String, _ session: UUID, _ generation: UUID) -> Bool {
        self.generation == generation && model?.account.account?.user.id == user
            && model?.account.cloudSessionID == session && identity == user
    }

    func accountDidChange() {
        guard let model, !model.isPreview else { return }
        let user = model.account.account?.user.id
        let session = model.account.cloudSessionID
        if identity != user || sessionID != session {
            // A deliberate sign-out or account switch revokes this Mac's opt-in.
            // A fresh process can still resume the same account's saved preference.
            if let previous = identity, previous != user { defaults.set(false, forKey: preferenceKey(previous)) }
            generation = UUID(); uploadTask?.cancel(); refreshTask?.cancel(); retryTask?.cancel()
            uploadTask = nil; refreshTask = nil; retryTask = nil
            identity = user; sessionID = session; pending = nil; lastFingerprint = nil
            status = nil; lastSavedAt = nil; recoveryFile = nil; message = nil; activity = .idle
            enabled = user.map {
                CloudBackupStartupPolicy.canResume(optedIn: defaults.bool(forKey: preferenceKey($0)),
                    fileExistedAtStartup: model.cloudLibraryExistedAtStartup,
                    libraryLoaded: model.canWriteLibrary, reviewRequired: needsLocalReview)
            } ?? false
            if user != nil { refresh() }
            startRetryLoop()
        }
        if enabled && model.account.hasVerifiedSubscription { libraryDidChange() }
    }

    private func startRetryLoop() {
        retryTask?.cancel()
        guard identity != nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.identity != nil else { return }
                if self.enabled && !self.isBusy { self.libraryDidChange() }
            }
        }
    }

    func refresh() {
        guard let model, !model.isPreview, let user = model.account.account?.user.id, !isBusy else { return }
        let session = model.account.cloudSessionID, generation = generation
        activity = .checking; message = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrent(user, session, generation) {
                    self.activity = .idle; self.refreshTask = nil
                    if self.enabled { self.libraryDidChange() }
                }
            }
            do {
                let result: CloudStatus = try await model.account.cloudRequest("api/cloud/status")
                guard self.isCurrent(user, session, generation), !Task.isCancelled else { return }
                self.status = result
                self.lastSavedAt = result.snapshots.first(where: { $0.deviceId == self.deviceID })?.createdAt
                if !result.enabled { self.message = "Cloud backup is temporarily unavailable. Your library stays on this Mac." }
                else if !result.canUpload && result.canRestore { self.message = "Backups are paused. You can still restore during your recovery period." }
            } catch {
                guard self.isCurrent(user, session, generation), !Task.isCancelled else { return }
                self.message = self.friendly(error)
            }
        }
    }

    func setEnabled(_ value: Bool) {
        guard let model, !model.isPreview, let user = model.account.account?.user.id else { return }
        if value {
            guard model.canWriteLibrary else {
                message = "Your local library could not be opened. Restore a cloud backup before enabling automatic backups."
                return
            }
            guard status?.enabled == true, status?.canUpload == true, !isBusy else { return }
            let alert = NSAlert()
            alert.messageText = "Back up this library with Savenest Pro?"
            let review = needsLocalReview ? "The previous local library was missing or could not be opened. This will back up the current \(model.library.links.count) links. " : ""
            alert.informativeText = review + "Your saved links, quick notes, tags, and collections will be uploaded to \(model.account.account?.user.email ?? "this account") and backed up automatically. Obsidian files and offline articles stay on this Mac. This is backup and restore, not live sync between Macs."
            alert.addButton(withTitle: "Turn on backups"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, model.account.account?.user.id == user else { return }
            needsLocalReview = false; defaults.set(false, forKey: reviewKey)
        }
        enabled = value; defaults.set(value, forKey: preferenceKey(user))
        message = value ? nil : "Automatic backups are off. Existing cloud backups follow their retention period."
        if value { libraryDidChange() }
        else {
            generation = UUID(); uploadTask?.cancel(); refreshTask?.cancel()
            uploadTask = nil; refreshTask = nil; pending = nil; activity = .idle
        }
    }

    func libraryDidChange() {
        guard let model, !model.isPreview, enabled, !needsLocalReview, let user = model.account.account?.user.id,
              model.canWriteLibrary, activity != .restoring else { return }
        // Never replace an in-flight upload. A newer local revision is sent afterwards.
        guard activity != .uploading else { return }
        uploadTask?.cancel()
        let session = model.account.cloudSessionID, generation = generation
        uploadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.isCurrent(user, session, generation), self.enabled, !self.isBusy else { return }
            await self.upload(user: user, session: session, generation: generation)
        }
    }

    func backUpNow() {
        guard enabled else { return }
        lastFingerprint = nil
        libraryDidChange()
    }

    private struct UploadResponse: Decodable { let snapshot: CloudSnapshotSummary }
    private struct DownloadResponse: Decodable { let snapshot: CloudLibrarySnapshot }
    private func upload(user: String, session: UUID, generation: UUID) async {
        guard let model else { return }
        // Compare only after debounce, so each local edit does not serialize the library.
        if let lastFingerprint, (try? CloudLibraryJSON.fingerprint(model.library)) == lastFingerprint { return }
        activity = .uploading; message = nil
        defer {
            if isCurrent(user, session, generation) {
                activity = .idle; uploadTask = nil
                if enabled, let current = try? CloudLibraryJSON.fingerprint(model.library), current != lastFingerprint,
                   message == nil { libraryDidChange() }
            }
        }
        do {
            if !model.account.hasVerifiedSubscription { _ = await model.account.refresh() }
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            guard model.account.hasVerifiedSubscription else {
                message = "Backups paused. Refresh your account to verify Pro."
                return
            }
            let access: CloudStatus = try await model.account.cloudRequest("api/cloud/status")
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            status = access
            guard access.enabled, access.canUpload else {
                message = "Backups paused. Refresh your account to check Pro access."
                return
            }
            let fingerprint = try CloudLibraryJSON.fingerprint(model.library)
            guard fingerprint != lastFingerprint else { return }
            // Reuse the ID if a response was lost; the server handles this idempotently.
            if pending?.fingerprint != fingerprint {
                pending = (CloudLibrarySnapshot(library: model.library, deviceId: deviceID), fingerprint)
            }
            guard let sending = pending else { return }
            let result: UploadResponse = try await model.account.cloudRequest("api/cloud/snapshots", method: "POST", body: sending.snapshot.encoded())
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            guard result.snapshot.id == sending.snapshot.snapshotId, result.snapshot.deviceId == deviceID else {
                throw CloudLibraryFailure.invalidSnapshot
            }
            lastFingerprint = sending.fingerprint; lastSavedAt = result.snapshot.createdAt; pending = nil
            message = "Library backed up."
            if let updated: CloudStatus = try? await model.account.cloudRequest("api/cloud/status"),
               isCurrent(user, session, generation), enabled, !Task.isCancelled { status = updated }
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            // Do not let the success message prevent a follow-up for edits made during the upload.
            if try CloudLibraryJSON.fingerprint(model.library) != lastFingerprint { message = nil }
        } catch {
            guard isCurrent(user, session, generation), !Task.isCancelled else { return }
            message = friendly(error)
        }
    }

    func restore(_ summary: CloudSnapshotSummary) async {
        guard let model, !model.isPreview, !isBusy, status?.canRestore == true,
              let user = model.account.account?.user.id else { return }
        let session = model.account.cloudSessionID, generation = generation
        uploadTask?.cancel(); uploadTask = nil
        activity = .restoring; message = nil
        defer { if isCurrent(user, session, generation) { activity = .idle } }
        do {
            let baseline = try model.cloudRestoreBaseline()
            let result: DownloadResponse = try await model.account.cloudRequest("api/cloud/snapshots/\(summary.id.uuidString.lowercased())")
            let snapshot = try result.snapshot.validated()
            _ = try snapshot.encoded()
            guard isCurrent(user, session, generation), !Task.isCancelled else { return }
            guard snapshot.snapshotId == summary.id, snapshot.deviceId == summary.deviceId else { throw CloudLibraryFailure.invalidSnapshot }
            guard try CloudLibraryJSON.fingerprint(model.library) == baseline.libraryFingerprint else { throw CloudLibraryFailure.libraryChanged }
            let alert = NSAlert()
            alert.messageText = "Restore this cloud backup?"
            let replacing = baseline.loadFailed ? "Replace the damaged library on this Mac" : "Replace the \(model.library.links.count) links on this Mac"
            alert.informativeText = "\(replacing) with \(snapshot.library.links.count) links from \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))? A recovery copy of your current library file will be kept on this Mac. Obsidian files and offline articles will not change. Automatic backups will turn off until you enable them again."
            alert.addButton(withTitle: "Restore backup"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard isCurrent(user, session, generation) else { throw CloudLibraryFailure.accountChanged }
            guard try CloudLibraryJSON.fingerprint(model.library) == baseline.libraryFingerprint else { throw CloudLibraryFailure.libraryChanged }
            let recovery = try model.restoreCloudLibrary(snapshot, baseline: baseline)
            recoveryFile = recovery
            needsLocalReview = false; defaults.set(false, forKey: reviewKey)
            enabled = false; defaults.set(false, forKey: preferenceKey(user)); pending = nil; lastFingerprint = nil
            message = recovery == nil ? "Library restored. Automatic backups are off." : "Library restored. Your previous library is kept in Savenest’s Cloud Recovery folder. Automatic backups are off."
        } catch {
            guard isCurrent(user, session, generation), !Task.isCancelled else { return }
            message = friendly(error)
        }
    }
    func revealRecoveryCopy() {
        guard let recoveryFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryFile])
    }
    private func friendly(_ error: Error) -> String {
        if error is URLError { return "Couldn’t connect to backups. Your library is safe; we’ll retry automatically." }
        return error.localizedDescription
    }
}
