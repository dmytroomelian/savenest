import CryptoKit
import Foundation

public enum CloudLibraryFailure: LocalizedError {
    case invalidSnapshot, tooLarge, libraryChanged, accountChanged, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "This cloud backup is not a valid Savenest library. Your local library is unchanged."
        case .tooLarge: return "This library exceeds the 2 MB cloud backup limit. Your local library is unchanged."
        case .libraryChanged: return "Your library changed while the backup was downloading. Review it and try restore again."
        case .accountChanged: return "Your account changed. Open Account & Pro again before continuing."
        case .unavailable: return "Backup is unavailable. Your local library is still available."
        }
    }
}

/// Only the library travels to cloud storage. Obsidian files, captured articles, browser history,
/// credentials, and device paths are not part of this versioned format.
public struct CloudLibrarySnapshot: Codable, Equatable {
    public let version: Int
    public let deviceId: UUID
    public let snapshotId: UUID
    public let createdAt: Date
    public let library: Library

    public init(library: Library, deviceId: UUID, snapshotId: UUID = UUID(), createdAt: Date = Date()) {
        version = 1; self.library = library; self.deviceId = deviceId
        self.snapshotId = snapshotId; self.createdAt = createdAt
    }

    public func validated() throws -> CloudLibrarySnapshot {
        guard version == 1, library.version == 1, CloudLibraryJSON.validDate(createdAt),
              CloudLibraryJSON.validID(deviceId), CloudLibraryJSON.validID(snapshotId),
              library.links.count <= 10_000, library.collections.count <= 1_000,
              library.collections.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && CloudLibraryJSON.validText($0, limit: 500) }),
              Set(library.collections).count == library.collections.count,
              Set(library.links.map(\.id)).count == library.links.count,
              Set(library.links.map { Library.identity($0.url) }).count == library.links.count else {
            throw CloudLibraryFailure.invalidSnapshot
        }
        for link in library.links {
            guard CloudLibraryJSON.validID(link.id), CloudLibraryJSON.validWebURL(link.url),
                  CloudLibraryJSON.validText(link.title, limit: 8_192), CloudLibraryJSON.validText(link.note, limit: 65_536),
                  CloudLibraryJSON.validText(link.browser, limit: 500), CloudLibraryJSON.validText(link.collection, limit: 500),
                  library.collections.contains(link.collection),
                  link.iconURL.map(CloudLibraryJSON.validWebURL) ?? true,
                  link.tags.count <= 100, link.tags.allSatisfy({ CloudLibraryJSON.validText($0, limit: 200) }),
                  CloudLibraryJSON.validDate(link.createdAt) else {
                throw CloudLibraryFailure.invalidSnapshot
            }
        }
        return self
    }

    public func encoded() throws -> Data {
        _ = try validated()
        let data = try CloudLibraryJSON.encoder().encode(self)
        guard data.count <= CloudLibraryJSON.maximumBytes else { throw CloudLibraryFailure.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> CloudLibrarySnapshot {
        guard data.count <= CloudLibraryJSON.maximumBytes else { throw CloudLibraryFailure.tooLarge }
        do { return try CloudLibraryJSON.decoder().decode(Self.self, from: data).validated() }
        catch let failure as CloudLibraryFailure { throw failure }
        catch { throw CloudLibraryFailure.invalidSnapshot }
    }
}

public enum CloudLibraryJSON {
    public static let maximumBytes = 2 * 1_024 * 1_024
    private static let datePattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#
    fileprivate static func validID(_ id: UUID) -> Bool {
        id.uuidString.range(of: #"^[A-F0-9]{8}-[A-F0-9]{4}-[1-8][A-F0-9]{3}-[89AB][A-F0-9]{3}-[A-F0-9]{12}$"#, options: .regularExpression) != nil
    }
    fileprivate static func validText(_ value: String, limit: Int) -> Bool {
        value.utf8.count <= limit && !value.contains("\0")
    }
    fileprivate static func validWebURL(_ value: String) -> Bool {
        validText(value, limit: 8_192) && !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 }
            && Library.validatedURL(value) != nil
    }
    fileprivate static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter(); whole.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard value.range(of: datePattern, options: .regularExpression) != nil else { throw CloudLibraryFailure.invalidSnapshot }
            if let date = fractional.date(from: value) { return date }
            guard let date = whole.date(from: value) else { throw CloudLibraryFailure.invalidSnapshot }
            return date
        }
        return decoder
    }
    /// Stable content fingerprint independent of snapshot ID, device, and upload time.
    public static func fingerprint(_ library: Library) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(library)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CloudSnapshotSummary: Codable, Equatable, Identifiable {
    public let id: UUID
    public let deviceId: UUID
    public let createdAt: Date
    public let linkCount: Int
    public let byteCount: Int
}

public struct CloudStatus: Codable, Equatable {
    public let enabled: Bool
    public let canUpload: Bool
    public let canRestore: Bool
    public let retentionEndsAt: Date?
    public let snapshots: [CloudSnapshotSummary]
}

public enum CloudBackupStartupPolicy {
    /// Missing storage must never turn a saved opt-in into an empty cloud replacement.
    /// The review latch survives local file recreation until explicit user action.
    public static func canResume(optedIn: Bool, fileExistedAtStartup: Bool,
                                 libraryLoaded: Bool, reviewRequired: Bool) -> Bool {
        optedIn && fileExistedAtStartup && libraryLoaded && !reviewRequired
    }
}

/// Restore is compare-and-replace, never an automatic merge. Save the exact previous
/// on-disk bytes before replacing them, so a failed or unwanted restore is recoverable.
public enum CloudLibraryRestore {
    private static func contents(_ file: LibraryFile) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.url.path) else { return nil }
        return try Data(contentsOf: file.url)
    }
    private static func fingerprint(_ bytes: Data?) -> String {
        guard let bytes else { return "missing" }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// Fingerprint raw bytes, including malformed files, without trying to decode them.
    public static func fileFingerprint(_ file: LibraryFile) throws -> String {
        fingerprint(try contents(file))
    }
    @discardableResult public static func apply(_ snapshot: CloudLibrarySnapshot, to file: LibraryFile,
                                               expectedFileFingerprint: String) throws -> URL? {
        let snapshot = try snapshot.validated()
        let previous = try contents(file)
        guard fingerprint(previous) == expectedFileFingerprint else {
            throw CloudLibraryFailure.libraryChanged
        }
        var recovery: URL?
        if let previous {
            let folder = file.url.deletingLastPathComponent().appendingPathComponent("Cloud Recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let target = folder.appendingPathComponent("before-restore-\(UUID().uuidString).json")
            try previous.write(to: target, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            recovery = target
        }
        try file.save(snapshot.library)
        return recovery
    }
}
