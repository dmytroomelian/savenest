import Foundation
import SaveNestCore

func runCloudLibraryChecks() throws {
    XCTAssertTrue(CloudBackupStartupPolicy.canResume(optedIn: true, fileExistedAtStartup: true, libraryLoaded: true, reviewRequired: false))
    XCTAssertFalse(CloudBackupStartupPolicy.canResume(optedIn: true, fileExistedAtStartup: false, libraryLoaded: true, reviewRequired: false))
    XCTAssertFalse(CloudBackupStartupPolicy.canResume(optedIn: true, fileExistedAtStartup: true, libraryLoaded: true, reviewRequired: true))
    XCTAssertFalse(CloudBackupStartupPolicy.canResume(optedIn: true, fileExistedAtStartup: true, libraryLoaded: false, reviewRequired: false))
    XCTAssertFalse(CloudBackupStartupPolicy.canResume(optedIn: false, fileExistedAtStartup: true, libraryLoaded: true, reviewRequired: false))
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
