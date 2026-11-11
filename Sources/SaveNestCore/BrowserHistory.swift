import Foundation
import CryptoKit
import SQLite3

public struct BrowserHistoryEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let browser: String
    public let profile: String
    public let lastVisited: Date
    public let visitCount: Int
    public var domain: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
    public init(url: String, title: String, browser: String, profile: String = "Default", lastVisited: Date, visitCount: Int = 1) {
        self.url = url; self.title = title; self.browser = browser; self.profile = profile
        self.lastVisited = lastVisited; self.visitCount = max(1, min(visitCount, 1_000_000))
        id = SHA256.hash(data: Data(Library.identity(url).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum HistoryDatabaseKind: String, Sendable { case chromium, firefox, safari }

public struct HistorySource: Identifiable, Equatable, Sendable {
    public let url: URL
    public let browser: String
    public let profile: String
    public let kind: HistoryDatabaseKind
    public var id: String { browser + ":" + profile }
    public init(url: URL, browser: String, profile: String, kind: HistoryDatabaseKind) {
        self.url = url; self.browser = browser; self.profile = profile; self.kind = kind
    }
}

public struct HistorySourceStatus: Sendable {
    public let source: HistorySource
    public let count: Int
    public let issue: String?
    public init(source: HistorySource, count: Int, issue: String? = nil) { self.source = source; self.count = count; self.issue = issue }
}

/// Reads a bounded recent slice from a live browser database. No copies, writes,
/// extensions, cookies, or credentials; SQLite handles a consistent read of WAL.
public enum BrowserHistoryReader {
    public static let maxEntries = 20_000
    public static let days = 90

    public static func read(_ source: HistorySource, now: Date = Date(), limit: Int = 2_000) throws -> [BrowserHistoryEntry] {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(source.url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let db { sqlite3_close(db) } }
        guard opened == SQLITE_OK, let db else { throw HistoryFailure.unavailable }
        sqlite3_busy_timeout(db, 100)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        // Cap expensive sorts on large or unexpectedly shaped browser databases.
        let deadline = Deadline(Date().addingTimeInterval(1.5))
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            return Task<Never, Never>.isCancelled || Date() > Unmanaged<Deadline>.fromOpaque(pointer).takeUnretainedValue().date ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(deadline) {} }
        let sql: String, epoch: Double, scale: Double
        switch source.kind {
        case .chromium:
            sql = "SELECT url, title, last_visit_time, visit_count FROM urls WHERE hidden = 0 AND last_visit_time >= ? ORDER BY last_visit_time DESC LIMIT ?"
            epoch = 11_644_473_600; scale = 1_000_000
        case .firefox:
            sql = "SELECT url, title, last_visit_date, visit_count FROM moz_places WHERE hidden = 0 AND last_visit_date >= ? ORDER BY last_visit_date DESC LIMIT ?"
            epoch = 0; scale = 1_000_000
        case .safari:
            sql = "SELECT i.url, v.title, v.visit_time, i.visit_count FROM history_visits v JOIN history_items i ON i.id = v.history_item WHERE v.visit_time >= ? ORDER BY v.visit_time DESC LIMIT ?"
            epoch = -978_307_200; scale = 1
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw HistoryFailure.schema }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, (now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 + epoch) * scale)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 5_000))))
        var result: [BrowserHistoryEntry] = [], seen = Set<String>()
        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw HistoryFailure.busy }
            let raw = string(0)
            guard raw.count <= 16_384, let url = Library.validatedURL(raw), seen.insert(Library.identity(raw)).inserted else { continue }
            let time = sqlite3_column_double(statement, 2) / scale - epoch
            guard time.isFinite, time <= now.timeIntervalSince1970 + 86400 else { continue }
            let title = String(string(1).prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(BrowserHistoryEntry(url: url.absoluteString, title: title.isEmpty ? url.host ?? raw : title,
                browser: source.browser, profile: source.profile, lastVisited: Date(timeIntervalSince1970: time), visitCount: Int(sqlite3_column_int(statement, 3))))
        }
        return result
    }

    /// Most recent visit wins across profiles. No browser history is persisted by Savenest.
    public static func merged(_ entries: [BrowserHistoryEntry]) -> [BrowserHistoryEntry] {
        var seen = Set<String>()
        return Array(entries.sorted { $0.lastVisited == $1.lastVisited ? $0.id < $1.id : $0.lastVisited > $1.lastVisited }
            .filter { Library.validatedURL($0.url) != nil && seen.insert(Library.identity($0.url)).inserted }.prefix(maxEntries))
    }

    private final class Deadline { let date: Date; init(_ date: Date) { self.date = date } }
    private enum HistoryFailure: LocalizedError {
        case unavailable, schema, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: return "History isn’t readable. Check browser file access in macOS Privacy & Security."
            case .schema: return "This browser’s history format isn’t supported yet."
            case .busy: return "History is busy. Refresh to try again."
            }
        }
    }
}
