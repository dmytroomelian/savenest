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
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var recoveryFile: URL?
    @Published private(set) var needsLocalReview = false
    private weak var model: AppModel?
    private var identity: String?
    private var sessionID: UUID?
    private var generation = UUID()
    private var uploadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var transfers = CloudLibraryTransferState()
    private var syncConflict = false
    private var connectionUnavailable = false
    private var operationFailed = false
    private var lastCheckedAt: Date?
    private let defaults: UserDefaults
    private let reviewKey = "savenest.cloud.local-library-review-required"
    let deviceID: UUID
    var isBusy: Bool { activity != .idle }
    var snapshots: [CloudSnapshotSummary] { status?.snapshots ?? [] }
    var hasAccount: Bool { model?.account.account != nil }
    var requiresLocalReview: Bool { needsLocalReview || syncConflict }
    var indicator: CloudSyncIndicator {
        guard let account = model?.account else { return .hidden }
        return CloudSyncIndicator.resolve(
            hasPro: account.account?.subscription.plan != nil,
            verified: account.hasVerifiedSubscription,
            enabled: enabled && status?.enabled == true && status?.canUpload == true,
            recentlyChecked: lastCheckedAt.map { Date().timeIntervalSince($0) < 150 } ?? false,
            acknowledged: transfers.lastSyncedFingerprint != nil,
            restoring: activity == .restoring,
            needsReview: needsLocalReview || syncConflict,
            offline: connectionUnavailable,
            failed: operationFailed || account.subscriptionUnavailable || status?.canUpload == false)
    }

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        let savedDevice = defaults.string(forKey: "savenest.cloud.device").flatMap(UUID.init(uuidString:))
        if let id = savedDevice { deviceID = id }
        else {
            deviceID = UUID()
            if !model.isPreview { defaults.set(deviceID.uuidString, forKey: "savenest.cloud.device") }
        }
        if !model.isPreview {
            // Record a valid first-run library before this device becomes a known install.
            // A write failure keeps automatic saving blocked until a later successful write.
            if savedDevice == nil, model.canWriteLibrary {
                do { try model.prepareLibraryForAutomaticSaving() }
                catch { operationFailed = true; message = error.localizedDescription }
            }
            if CloudBackupStartupPolicy.needsReview(knownDevice: savedDevice != nil,
                fileExistedAtStartup: model.cloudLibraryExistedAtStartup, libraryLoaded: model.canWriteLibrary) {
                defaults.set(true, forKey: reviewKey)
            }
            needsLocalReview = defaults.bool(forKey: reviewKey)
        }
    }
    private func isCurrent(_ user: String, _ session: UUID, _ generation: UUID) -> Bool {
        self.generation == generation && model?.account.account?.user.id == user
            && model?.account.cloudSessionID == session && identity == user
    }

    func accountDidChange() {
        guard let model, !model.isPreview else { return }
        let user = model.account.account?.user.id
        let session = model.account.cloudSessionID
        if identity != user || sessionID != session {
            // No acknowledgement or pending request may cross an account/session boundary.
            generation = UUID(); uploadTask?.cancel(); refreshTask?.cancel(); retryTask?.cancel()
            uploadTask = nil; refreshTask = nil; retryTask = nil
            identity = user; sessionID = session; transfers = CloudLibraryTransferState(); syncConflict = false
            status = nil; lastSavedAt = nil; lastSyncedAt = nil; recoveryFile = nil; message = nil; activity = .idle
            enabled = false; connectionUnavailable = false; operationFailed = false; lastCheckedAt = nil
            if user != nil { refresh() }
            startRetryLoop()
        }
        if !model.account.hasVerifiedSubscription {
            enabled = false; uploadTask?.cancel(); uploadTask = nil
        } else if !enabled && !isBusy {
            refresh()
        } else if enabled { libraryDidChange() }
    }

    private func startRetryLoop() {
        retryTask?.cancel()
        guard identity != nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.identity != nil else { return }
                if !self.isBusy { self.refresh() }
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
                if !model.account.hasVerifiedSubscription { _ = await model.account.refresh() }
                guard self.isCurrent(user, session, generation), !Task.isCancelled else { return }
                let result: CloudStatus = try await model.account.cloudRequest("api/cloud/status")
                guard self.isCurrent(user, session, generation), !Task.isCancelled else { return }
                self.status = result
                self.lastSavedAt = result.snapshots.first(where: { $0.deviceId == self.deviceID })?.createdAt
                self.lastSyncedAt = result.libraries?.first(where: { $0.deviceId == self.deviceID })?.updatedAt
                self.lastCheckedAt = Date(); self.connectionUnavailable = false
                if (try? self.transfers.needsWork(for: model.library)) == false { self.operationFailed = false }
                self.enabled = CloudBackupStartupPolicy.canStart(verifiedPro: model.account.hasVerifiedSubscription,
                    libraryLoaded: model.canWriteLibrary, reviewRequired: self.requiresLocalReview,
                    serviceAvailable: result.enabled, canUpload: result.canUpload)
                if !result.enabled { self.operationFailed = true; self.message = "Temporarily unavailable. Your changes are safe on this Mac." }
                else if !result.canUpload && result.canRestore { self.message = "Pro has ended. You can still restore your library during the recovery period." }
            } catch {
                guard self.isCurrent(user, session, generation), !Task.isCancelled else { return }
                self.recordFailure(error)
            }
        }
    }

    /// Explicit recovery choice only; ordinary Pro activation needs no toggle.
    func setEnabled(_ value: Bool) {
        guard value, let model, !model.isPreview, let user = model.account.account?.user.id,
              model.account.hasVerifiedSubscription, status?.enabled == true, status?.canUpload == true, !isBusy else { return }
        guard model.canWriteLibrary else {
            message = "Your library couldn’t be opened. Restore a saved copy to continue."
            return
        }
        if needsLocalReview || syncConflict {
            let alert = NSAlert()
            alert.messageText = "Use this library?"
            alert.informativeText = "Save the current \(model.library.links.count) links to \(model.account.account?.user.email ?? "your Pro account")? This may replace this Mac’s previously saved copy. Restore a previous library first if these links are incomplete."
            alert.addButton(withTitle: "Use this library"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, model.account.account?.user.id == user else { return }
        }
        needsLocalReview = false; defaults.set(false, forKey: reviewKey)
        syncConflict = false; connectionUnavailable = false; operationFailed = false
        enabled = true; message = nil; transfers = CloudLibraryTransferState()
        libraryDidChange()
    }

    func libraryDidChange() {
        guard let model, !model.isPreview, enabled, !needsLocalReview, !syncConflict, let user = model.account.account?.user.id,
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
        guard enabled, !syncConflict else { return }
        transfers.requestBackup()
        libraryDidChange()
    }

    private struct UploadResponse: Decodable { let snapshot: CloudSnapshotSummary }
    private struct SyncResponse: Decodable { let library: CloudLibraryRevisionSummary }
    private struct DownloadResponse: Decodable { let snapshot: CloudLibrarySnapshot }
    private func upload(user: String, session: UUID, generation: UUID) async {
        guard let model else { return }
        // Compare only after debounce, so each local edit does not serialize the library.
        if (try? transfers.needsWork(for: model.library)) == false { return }
        activity = .uploading; message = nil
        defer {
            if isCurrent(user, session, generation) {
                activity = .idle; uploadTask = nil
                if enabled, !syncConflict, (try? transfers.needsWork(for: model.library)) == true,
                   message == nil { libraryDidChange() }
            }
        }
        do {
            if !model.account.hasVerifiedSubscription { _ = await model.account.refresh() }
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            guard model.account.hasVerifiedSubscription else {
                enabled = false; operationFailed = true
                message = "Couldn’t verify Pro. Refresh your account to continue."
                return
            }
            try model.prepareLibraryForAutomaticSaving()
            let access: CloudStatus = try await model.account.cloudRequest("api/cloud/status")
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            status = access; lastCheckedAt = Date()
            guard access.enabled, access.canUpload else {
                enabled = false; operationFailed = true
                message = "Couldn’t verify Pro access. Refresh your account to continue."
                return
            }
            if let sending = try transfers.syncTransfer(for: model.library, deviceID: deviceID,
                previousRevision: access.libraries?.first(where: { $0.deviceId == deviceID })?.id) {
                let result: SyncResponse = try await model.account.cloudRequest("api/cloud/library", method: "POST",
                    body: sending.snapshot.encoded(), ifMatch: sending.ifMatch)
                guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
                guard result.library.id == sending.snapshot.snapshotId, result.library.deviceId == deviceID else {
                    throw CloudLibraryFailure.invalidSnapshot
                }
                transfers.didSync(sending); lastSyncedAt = result.library.updatedAt
                connectionUnavailable = false; operationFailed = false
            }
            // Back up the same acknowledged library, then sync any edits made in flight.
            // Automatic daily backups run on the server from the current database copy.
            if transfers.backupRequested,
               try CloudLibraryJSON.fingerprint(model.library) == transfers.lastSyncedFingerprint,
               let sending = try transfers.backupTransfer(for: model.library, deviceID: deviceID) {
                let result: UploadResponse = try await model.account.cloudRequest("api/cloud/snapshots", method: "POST", body: sending.snapshot.encoded())
                guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
                guard result.snapshot.id == sending.snapshot.snapshotId, result.snapshot.deviceId == deviceID else {
                    throw CloudLibraryFailure.invalidSnapshot
                }
                transfers.didBackUp(sending); lastSavedAt = result.snapshot.createdAt
            }
            message = nil
            let updated: CloudStatus = try await model.account.cloudRequest("api/cloud/status")
            guard isCurrent(user, session, generation), enabled, !Task.isCancelled else { return }
            status = updated; lastCheckedAt = Date()
            lastSavedAt = updated.snapshots.first(where: { $0.deviceId == deviceID })?.createdAt
            lastSyncedAt = updated.libraries?.first(where: { $0.deviceId == deviceID })?.updatedAt ?? lastSyncedAt
            // Do not let the success message prevent a follow-up for edits made during the upload.
            if try transfers.needsWork(for: model.library) { message = nil }
        } catch {
            guard isCurrent(user, session, generation), !Task.isCancelled else { return }
            if case CloudLibraryFailure.revisionConflict = error { syncConflict = true }
            recordFailure(error)
        }
    }

    func restore(_ summary: CloudSnapshotSummary) async {
        guard let model, !model.isPreview, !isBusy, status?.canRestore == true,
              let user = model.account.account?.user.id else { return }
        let session = model.account.cloudSessionID, generation = generation
        uploadTask?.cancel(); uploadTask = nil
        activity = .restoring; message = nil
        defer {
            if isCurrent(user, session, generation) {
                activity = .idle
                if enabled && !needsLocalReview { libraryDidChange() }
            }
        }
        do {
            let baseline = try model.cloudRestoreBaseline()
            let result: DownloadResponse = try await model.account.cloudRequest("api/cloud/snapshots/\(summary.id.uuidString.lowercased())")
            let snapshot = try result.snapshot.validated()
            _ = try snapshot.encoded()
            guard isCurrent(user, session, generation), !Task.isCancelled else { return }
            guard snapshot.snapshotId == summary.id, snapshot.deviceId == summary.deviceId else { throw CloudLibraryFailure.invalidSnapshot }
            guard try CloudLibraryJSON.fingerprint(model.library) == baseline.libraryFingerprint else { throw CloudLibraryFailure.libraryChanged }
            let alert = NSAlert()
            alert.messageText = "Restore this library?"
            let replacing = baseline.loadFailed ? "Replace the damaged library on this Mac" : "Replace the \(model.library.links.count) links on this Mac"
            alert.informativeText = "\(replacing) with \(snapshot.library.links.count) links from \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))? A recovery copy of your current library file will be kept on this Mac. Obsidian files and offline articles will not change. Savenest will save the restored library automatically with Pro."
            alert.addButton(withTitle: "Restore library"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard isCurrent(user, session, generation) else { throw CloudLibraryFailure.accountChanged }
            guard try CloudLibraryJSON.fingerprint(model.library) == baseline.libraryFingerprint else { throw CloudLibraryFailure.libraryChanged }
            let recovery = try model.restoreCloudLibrary(snapshot, baseline: baseline)
            recoveryFile = recovery
            needsLocalReview = false; defaults.set(false, forKey: reviewKey)
            transfers = CloudLibraryTransferState(); syncConflict = false
            connectionUnavailable = false; operationFailed = false
            enabled = model.account.hasVerifiedSubscription && status?.canUpload == true
            message = recovery == nil ? "Library restored." : "Library restored. Your previous library is kept on this Mac."
        } catch {
            guard isCurrent(user, session, generation), !Task.isCancelled else { return }
            recordFailure(error)
        }
    }
    func revealRecoveryCopy() {
        guard let recoveryFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryFile])
    }
    private func recordFailure(_ error: Error) {
        connectionUnavailable = error is URLError
        operationFailed = true
        message = connectionUnavailable
            ? "You’re offline. Changes are safe on this Mac and will be saved automatically when you reconnect."
            : error.localizedDescription
    }
}
