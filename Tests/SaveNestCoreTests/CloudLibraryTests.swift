import Foundation
import SaveNestCore

func runCloudLibraryChecks() throws {
    try runCloudTransferChecks()
    runCloudReviewHoldChecks()
    // Fresh installs auto-start; lost/damaged known libraries remain protected.
    XCTAssertFalse(CloudBackupStartupPolicy.needsReview(knownDevice: false, fileExistedAtStartup: false, libraryLoaded: true))
    XCTAssertFalse(CloudBackupStartupPolicy.needsReview(knownDevice: true, fileExistedAtStartup: true, libraryLoaded: true))
    XCTAssertTrue(CloudBackupStartupPolicy.needsReview(knownDevice: true, fileExistedAtStartup: false, libraryLoaded: true))
    XCTAssertTrue(CloudBackupStartupPolicy.needsReview(knownDevice: false, fileExistedAtStartup: true, libraryLoaded: false))
    XCTAssertTrue(CloudBackupStartupPolicy.canStart(verifiedPro: true, libraryLoaded: true, reviewRequired: false, serviceAvailable: true, canUpload: true))
    XCTAssertFalse(CloudBackupStartupPolicy.canStart(verifiedPro: false, libraryLoaded: true, reviewRequired: false, serviceAvailable: true, canUpload: true))
    XCTAssertFalse(CloudBackupStartupPolicy.canStart(verifiedPro: true, libraryLoaded: true, reviewRequired: true, serviceAvailable: true, canUpload: true))
    XCTAssertFalse(CloudBackupStartupPolicy.canStart(verifiedPro: true, libraryLoaded: false, reviewRequired: false, serviceAvailable: true, canUpload: true))
    XCTAssertFalse(CloudBackupStartupPolicy.canStart(verifiedPro: true, libraryLoaded: true, reviewRequired: false, serviceAvailable: false, canUpload: true))
    XCTAssertFalse(CloudBackupStartupPolicy.canStart(verifiedPro: true, libraryLoaded: true, reviewRequired: false, serviceAvailable: true, canUpload: false))
    func indicator(pro: Bool = true, verified: Bool = true, enabled: Bool = true, recent: Bool = true,
                   ack: Bool = true, restoring: Bool = false, review: Bool = false, offline: Bool = false,
                   failed: Bool = false) -> CloudSyncIndicator {
        CloudSyncIndicator.resolve(hasPro: pro, verified: verified, enabled: enabled,
            recentlyChecked: recent, acknowledged: ack, restoring: restoring,
            needsReview: review, offline: offline, failed: failed)
    }
    XCTAssertEqual(indicator(), .active)
    XCTAssertEqual(indicator(pro: false), .hidden)
    XCTAssertEqual(indicator(ack: false), .checking)
    XCTAssertEqual(indicator(verified: false), .checking)
    XCTAssertEqual(indicator(enabled: false), .checking)
    XCTAssertEqual(indicator(recent: false), .checking)
    XCTAssertEqual(indicator(offline: true, failed: true), .offline)
    XCTAssertEqual(indicator(review: true), .attention)
    XCTAssertEqual(indicator(failed: true), .attention)
    XCTAssertEqual(indicator(restoring: true), .restoring)
    let device = UUID()
    var link = SavedLink(url: "https://example.com/article", title: "A saved article")
    link.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    link.note = "A quick note\n\"Quoted\" — café 🌱"; link.tags = ["Research", "Écriture"]; link.isFavorite = true
    link.iconURL = "https://example.com/icon.png"; link.importance = .important
    var library = Library(); library.links = [link]
    let snapshot = CloudLibrarySnapshot(library: library, deviceId: device, createdAt: Date(timeIntervalSince1970: 1_700_000_001))
    let bytes = try snapshot.encoded()
    // Optional cross-language contract fixture. Contains synthetic data only.
    if let path = ProcessInfo.processInfo.environment["SAVENEST_CLOUD_FIXTURE_PATH"], !path.isEmpty {
        try bytes.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }
    let decoded = try CloudLibrarySnapshot.decode(bytes)
    XCTAssertEqual(decoded, snapshot)
    let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    XCTAssertEqual(Set(object.keys), Set(["version", "snapshotId", "deviceId", "createdAt", "library"]))
    let jsonLibrary = object["library"] as! [String: Any]
    XCTAssertEqual(Set(jsonLibrary.keys), Set(["version", "links", "collections"]))
    let jsonLink = (jsonLibrary["links"] as! [[String: Any]])[0]
    XCTAssertEqual(jsonLink["createdAt"] as? String, "2023-11-14T22:13:20.000Z")
    XCTAssertNil(jsonLink["markdown"]); XCTAssertNil(jsonLink["articleHTML"])
    XCTAssertNil(jsonLink["accessToken"]); XCTAssertNil(jsonLink["filePath"])

    var invalid = object; invalid["version"] = 2
    XCTAssertThrowsError(try CloudLibrarySnapshot.decode(JSONSerialization.data(withJSONObject: invalid)))
    invalid = object; invalid["createdAt"] = 123
    XCTAssertThrowsError(try CloudLibrarySnapshot.decode(JSONSerialization.data(withJSONObject: invalid)))
    invalid = object; invalid["createdAt"] = "2023-11-14T22:13:21Z"
    try XCTAssertEqual(try CloudLibrarySnapshot.decode(JSONSerialization.data(withJSONObject: invalid)).createdAt, snapshot.createdAt)
    XCTAssertThrowsError(try CloudLibrarySnapshot.decode(Data(repeating: 32, count: CloudLibraryJSON.maximumBytes + 1)))

    var duplicate = library; duplicate.links.append(link)
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: duplicate, deviceId: device).encoded())
    var sameURL = link; sameURL.id = UUID(); sameURL.url = "https://EXAMPLE.com/article"
    duplicate.links[1] = sameURL
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: duplicate, deviceId: device).encoded())
    var unsafe = library; unsafe.links[0].url = "file:///private/secret.txt"
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    unsafe = library; unsafe.links[0].url = "https://user:secret@example.com/private"
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    for invalidURL in ["https://example.com/has space", "https://example.com/\n", "https://example.com/\u{7f}"] {
        unsafe = library; unsafe.links[0].url = invalidURL
        XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    }
    for icon in ["", "data:image/png;base64,abcd", "/relative.png", "https://user:secret@example.com/icon.png"] {
        unsafe = library; unsafe.links[0].iconURL = icon
        XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    }
    unsafe = library; unsafe.links[0].note = "Contains\0NUL"
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    unsafe = library; unsafe.links[0].collection = "Missing"
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    unsafe = library; unsafe.collections.append("Inbox")
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    unsafe = library; unsafe.collections.append("  ")
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    unsafe = library; unsafe.links[0].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: unsafe, deviceId: device).encoded())
    var oversized = library; oversized.links[0].note = String(repeating: "a", count: 65_537)
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: oversized, deviceId: device).encoded())
    oversized.links = (0..<80).map { index in
        var value = SavedLink(url: "https://example.com/\(index)", title: "Large note")
        value.note = String(repeating: "a", count: 65_536); return value
    }
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: oversized, deviceId: device).encoded())

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SaveNestCloudChecks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = LibraryFile(url: directory.appendingPathComponent("library.json"))
    var original = Library(); original.links = [SavedLink(url: "https://local.test", title: "Keep this safe")]
    try file.save(original)
    let originalBytes = try Data(contentsOf: file.url)
    let fingerprint = try CloudLibraryJSON.fingerprint(original)
    let fileFingerprint = try CloudLibraryRestore.fileFingerprint(file)
    var changed = original; changed.links[0].note = "Edit while download runs"
    XCTAssertFalse(try CloudLibraryJSON.fingerprint(changed) == fingerprint)
    try file.save(changed)
    XCTAssertThrowsError(try CloudLibraryRestore.apply(snapshot, to: file, expectedFileFingerprint: fileFingerprint))
    try XCTAssertEqual(try file.load(), changed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Cloud Recovery").path))

    try file.save(original)
    let recovery = try CloudLibraryRestore.apply(snapshot, to: file, expectedFileFingerprint: fileFingerprint)
    XCTAssertNotNil(recovery)
    try XCTAssertEqual(try Data(contentsOf: recovery!), originalBytes)
    try XCTAssertEqual(try file.load(), library)
    let permissions = try FileManager.default.attributesOfItem(atPath: recovery!.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)

    // If a recovery copy cannot be saved, replacement must not begin.
    try FileManager.default.removeItem(at: directory.appendingPathComponent("Cloud Recovery"))
    try Data("blocked".utf8).write(to: directory.appendingPathComponent("Cloud Recovery"))
    try file.save(original)
    XCTAssertThrowsError(try CloudLibraryRestore.apply(snapshot, to: file, expectedFileFingerprint: fileFingerprint))
    try XCTAssertEqual(try Data(contentsOf: file.url), originalBytes)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("Cloud Recovery"))

    // Corrupt files can be recovered without decoding or discarding their original bytes.
    let damaged = Data([0xff, 0x00, 0x7b, 0x22])
    try damaged.write(to: file.url, options: [.atomic])
    let damagedFingerprint = try CloudLibraryRestore.fileFingerprint(file)
    let changedDamage = Data("different damage".utf8)
    try changedDamage.write(to: file.url, options: [.atomic])
    XCTAssertThrowsError(try CloudLibraryRestore.apply(snapshot, to: file, expectedFileFingerprint: damagedFingerprint))
    try XCTAssertEqual(try Data(contentsOf: file.url), changedDamage)
    try damaged.write(to: file.url, options: [.atomic])
    let damagedRecovery = try CloudLibraryRestore.apply(snapshot, to: file, expectedFileFingerprint: damagedFingerprint)
    try XCTAssertEqual(try Data(contentsOf: damagedRecovery!), damaged)
    try XCTAssertEqual(try file.load(), library)

    let missing = LibraryFile(url: directory.appendingPathComponent("missing.json"))
    let missingFingerprint = try CloudLibraryRestore.fileFingerprint(missing)
    try missing.save(changed)
    XCTAssertThrowsError(try CloudLibraryRestore.apply(snapshot, to: missing, expectedFileFingerprint: missingFingerprint))
    try XCTAssertEqual(try missing.load(), changed)
    try FileManager.default.removeItem(at: missing.url)
    XCTAssertNil(try CloudLibraryRestore.apply(snapshot, to: missing, expectedFileFingerprint: missingFingerprint))
    try XCTAssertEqual(try missing.load(), library)
    print("Cloud: payload limits, missing-library upload pause, stale restore rejection, and damaged-file recovery passed")
}

private func runCloudTransferChecks() throws {
    let device = UUID(), revision = UUID()
    var state = CloudLibraryTransferState()
    var library = Library()
    library.links = [SavedLink(url: "https://example.com/sync", title: "Before edit")]
    let first = try state.syncTransfer(for: library, deviceID: device, previousRevision: nil)!
    XCTAssertEqual(first.ifMatch, "none")
    // A lost response retries the same content and original precondition.
    let retry = try state.syncTransfer(for: library, deviceID: device, previousRevision: revision)!
    XCTAssertEqual(retry.snapshot, first.snapshot)
    XCTAssertEqual(retry.ifMatch, "none")
    XCTAssertTrue(try state.needsWork(for: library))
    state.didSync(first)
    XCTAssertFalse(try state.needsWork(for: library))
    XCTAssertNil(try state.syncTransfer(for: library, deviceID: device, previousRevision: first.snapshot.snapshotId))
    XCTAssertNil(try state.backupTransfer(for: library, deviceID: device))

    // Server may accept an edit whose response is lost, then the user undoes it.
    // Reconcile the undo even though it matches our last acknowledged content.
    var revertedState = state
    var temporaryEdit = library; temporaryEdit.links[0].note = "Edit with lost response"
    let uncertain = try revertedState.syncTransfer(for: temporaryEdit, deviceID: device, previousRevision: first.snapshot.snapshotId)!
    XCTAssertTrue(try revertedState.needsWork(for: library))
    let undo = try revertedState.syncTransfer(for: library, deviceID: device, previousRevision: uncertain.snapshot.snapshotId)!
    XCTAssertEqual(undo.snapshot.library, library)
    XCTAssertEqual(undo.ifMatch, uncertain.snapshot.snapshotId.uuidString.lowercased())
    XCTAssertFalse(undo.snapshot.snapshotId == uncertain.snapshot.snapshotId)
    revertedState.didSync(undo)
    XCTAssertFalse(try revertedState.needsWork(for: library))

    library.links[0].title = "After edit"; library.links[0].note = "New note"; library.links[0].tags = ["Changed"]
    let edited = try state.syncTransfer(for: library, deviceID: device, previousRevision: first.snapshot.snapshotId)!
    XCTAssertEqual(edited.snapshot.library, library)
    XCTAssertEqual(edited.ifMatch, first.snapshot.snapshotId.uuidString.lowercased())
    XCTAssertFalse(edited.snapshot.snapshotId == first.snapshot.snapshotId)
    // Edits while an upload is in flight remain pending after its acknowledgement.
    library.links[0].isFavorite = true
    state.didSync(edited)
    XCTAssertTrue(try state.needsWork(for: library))
    let newer = try state.syncTransfer(for: library, deviceID: device, previousRevision: edited.snapshot.snapshotId)!
    state.didSync(newer)

    library.links.removeAll()
    let deleted = try state.syncTransfer(for: library, deviceID: device, previousRevision: newer.snapshot.snapshotId)!
    XCTAssertEqual(deleted.snapshot.library.links.count, 0)
    state.didSync(deleted)
    XCTAssertFalse(try state.needsWork(for: library))

    // Manual backup still works without a content change; failure keeps its ID.
    state.requestBackup()
    XCTAssertTrue(try state.needsWork(for: library))
    XCTAssertNil(try state.syncTransfer(for: library, deviceID: device, previousRevision: deleted.snapshot.snapshotId))
    let backup = try state.backupTransfer(for: library, deviceID: device)!
    try XCTAssertEqual(try state.backupTransfer(for: library, deviceID: device)!.snapshot, backup.snapshot)
    state.didBackUp(backup)
    XCTAssertFalse(try state.needsWork(for: library))
    state.requestBackup()
    XCTAssertFalse(try state.backupTransfer(for: library, deviceID: device)!.snapshot.snapshotId == backup.snapshot.snapshotId)

    // An older backend can be read for recovery without claiming sync succeeded.
    let oldStatus = Data(#"{"enabled":true,"canUpload":true,"canRestore":true,"snapshots":[]}"#.utf8)
    XCTAssertNil(try CloudLibraryJSON.decoder().decode(CloudStatus.self, from: oldStatus).libraries)
    let status = Data("{\"enabled\":true,\"canUpload\":true,\"canRestore\":true,\"snapshots\":[],\"libraries\":[{\"id\":\"\(revision.uuidString)\",\"deviceId\":\"\(device.uuidString)\",\"updatedAt\":\"2026-11-11T12:00:00.000Z\",\"linkCount\":0,\"byteCount\":120}]}".utf8)
    let decoded = try CloudLibraryJSON.decoder().decode(CloudStatus.self, from: status)
    XCTAssertEqual(decoded.libraries?.first?.id, revision)
    XCTAssertEqual(decoded.libraries?.first?.deviceId, device)
}

private func runCloudReviewHoldChecks() {
    let suite = "SavenestReviewHoldChecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstSession = CloudLibraryReviewHold(defaults: defaults)
    XCTAssertFalse(firstSession.isRequired)
    firstSession.require()
    // Recreating account/controller state must not silently resume saving.
    let nextSession = CloudLibraryReviewHold(defaults: UserDefaults(suiteName: suite)!)
    XCTAssertTrue(nextSession.isRequired)
    XCTAssertFalse(CloudBackupStartupPolicy.canStart(verifiedPro: true, libraryLoaded: true,
        reviewRequired: nextSession.isRequired, serviceAvailable: true, canUpload: true))
    // Only the explicit recovery choice clears the persisted hold.
    nextSession.clear()
    XCTAssertFalse(CloudLibraryReviewHold(defaults: UserDefaults(suiteName: suite)!).isRequired)
}
