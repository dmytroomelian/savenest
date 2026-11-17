import Foundation

public struct ActivityDay: Codable, Equatable, Sendable {
    public let date: String
    public let saved: Int
    public let finished: Int
    public init(date: String, saved: Int, finished: Int) {
        self.date = date; self.saved = saved; self.finished = finished
    }
}

/// One entry in the selected day's event feed. `id` stays the saved-link UUID
/// so the renderer can still open the link; `eventID` identifies this specific
/// save or finish for pagination and focus restoration.
public struct ActivityLink: Codable, Equatable, Sendable {
    public let id: String
    public let eventID: String
    public let action: String
    public let occurredAt: String
    public let title: String
    public let url: String
    public let domain: String
    public let saved: Bool
    public let finished: Bool
    public init(id: String, eventID: String, action: String, occurredAt: String,
                title: String, url: String, domain: String, saved: Bool, finished: Bool) {
        self.id = id; self.eventID = eventID; self.action = action; self.occurredAt = occurredAt
        self.title = title; self.url = url
        self.domain = domain; self.saved = saved; self.finished = finished
    }
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public let year: Int
    public let years: [Int]
    public let savedCount: Int
    public let finishedCount: Int
    public let unfinishedCount: Int
    public let undatedFinishedCount: Int
    public let days: [ActivityDay]
    public let links: [ActivityLink]
    public let totalLinks: Int
    public let offset: Int
    public let hasMore: Bool

    public init(year: Int, years: [Int], savedCount: Int, finishedCount: Int,
                unfinishedCount: Int, undatedFinishedCount: Int, days: [ActivityDay],
                links: [ActivityLink], totalLinks: Int, offset: Int, hasMore: Bool) {
        self.year = year; self.years = years; self.savedCount = savedCount
        self.finishedCount = finishedCount; self.unfinishedCount = unfinishedCount
        self.undatedFinishedCount = undatedFinishedCount; self.days = days
        self.links = links; self.totalLinks = totalLinks; self.offset = offset; self.hasMore = hasMore
    }
}

public enum LibraryActivityError: LocalizedError, Equatable {
    case invalidYear, invalidKind, invalidDay, futureDay, invalidOffset, invalidLimit
    public var errorDescription: String? {
        switch self {
        case .invalidYear: return "year must be from 1 to 9998."
        case .invalidKind: return "kind must be all, saved, or finished."
        case .invalidDay: return "day must be a valid yyyy-MM-dd date in the requested year."
        case .futureDay: return "day must not be in the future."
        case .invalidOffset: return "offset must be zero or greater."
        case .invalidLimit: return "limit must be from 1 to 100."
        }
    }
}

/// Read-only activity projection over the complete saved-link library.
/// History belongs to the link, so restored links keep activity and deletions remove it.
public enum LibraryActivity {
    public static func query(library: Library, year: Int, kind: String = "all", day: String? = nil,
                             offset: Int = 0, limit: Int = 100, calendar: Calendar = .current,
                             now: Date = Date()) throws -> ActivitySnapshot {
        guard (1...9998).contains(year) else { throw LibraryActivityError.invalidYear }
        let kind = kind.lowercased()
        guard ["all", "saved", "finished"].contains(kind) else { throw LibraryActivityError.invalidKind }
        guard offset >= 0 else { throw LibraryActivityError.invalidOffset }
        guard (1...100).contains(limit) else { throw LibraryActivityError.invalidLimit }

        let local = gregorian(calendar)
        guard let yearStart = date(year: year, month: 1, day: 1, calendar: local) else {
            throw LibraryActivityError.invalidYear
        }
        let start = local.startOfDay(for: yearStart)

        var selectedDay: Date?
        if let day {
            guard let parsed = parse(day: day, year: year, calendar: local) else {
                throw LibraryActivityError.invalidDay
            }
            guard parsed <= now else { throw LibraryActivityError.futureDay }
            selectedDay = parsed
        }

        var savedByDay: [Date: Int] = [:]
        var finishedByDay: [Date: Int] = [:]
        for link in library.links {
            if link.createdAt <= now, local.component(.year, from: link.createdAt) == year {
                let key = local.startOfDay(for: link.createdAt)
                savedByDay[key, default: 0] += 1
            }
            var seenDays = Set<Date>()
            for finished in link.archiveHistory where finished <= now && local.component(.year, from: finished) == year {
                let key = local.startOfDay(for: finished)
                // Repeated archives on the same local day are one finished event for this link.
                if seenDays.insert(key).inserted { finishedByDay[key, default: 0] += 1 }
            }
        }

        var days: [ActivityDay] = []
        var cursor = start
        while local.component(.year, from: cursor) == year {
            let parts = local.dateComponents([.year, .month, .day], from: cursor)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { break }
            days.append(ActivityDay(date: dayString(year: y, month: m, day: d),
                                    saved: savedByDay[cursor] ?? 0,
                                    finished: finishedByDay[cursor] ?? 0))
            guard let next = local.date(byAdding: .day, value: 1, to: cursor) else { break }
            let nextStart = local.startOfDay(for: next)
            guard nextStart > cursor else { break }
            cursor = nextStart
        }

        var links: [ActivityLink] = []
        var totalLinks = 0
        var hasMore = false
        if let selectedDay {
            guard let dayEnd = local.date(byAdding: .day, value: 1, to: selectedDay) else {
                throw LibraryActivityError.invalidDay
            }
            struct Candidate {
                let link: SavedLink
                let action: String
                let occurredAt: Date
                let eventID: String
            }
            var candidates: [Candidate] = []
            for link in library.links {
                let savedAt = isWithin(link.createdAt, from: selectedDay, to: dayEnd, now: now)
                    ? link.createdAt : nil
                // The heatmap counts one finish per link/day; the feed shows the latest
                // archived timestamp from that same local day.
                let finishedAt = link.archiveHistory.filter {
                    isWithin($0, from: selectedDay, to: dayEnd, now: now)
                }.max()
                let parts = local.dateComponents([.year, .month, .day], from: selectedDay)
                let dayKey = dayString(year: parts.year ?? year, month: parts.month ?? 1,
                                       day: parts.day ?? 1)
                if kind != "finished", let savedAt {
                    candidates.append(Candidate(
                        link: link, action: "saved", occurredAt: savedAt,
                        eventID: "\(link.id.uuidString):saved"))
                }
                if kind != "saved", let finishedAt {
                    candidates.append(Candidate(
                        link: link, action: "finished", occurredAt: finishedAt,
                        eventID: "\(link.id.uuidString):finished:\(dayKey)"))
                }
            }
            candidates.sort {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.eventID < $1.eventID
            }
            totalLinks = candidates.count
            let page = candidates.dropFirst(offset).prefix(limit)
            links = page.map {
                let saved = $0.action == "saved"
                return ActivityLink(
                    id: $0.link.id.uuidString, eventID: $0.eventID, action: $0.action,
                    occurredAt: iso8601($0.occurredAt), title: $0.link.title,
                    url: $0.link.url, domain: $0.link.domain,
                    saved: saved, finished: !saved)
            }
            hasMore = offset + links.count < totalLinks
        }

        var available = Set<Int>()
        for link in library.links {
            for event in [link.createdAt] + link.archiveHistory where event <= now {
                let eventYear = local.component(.year, from: event)
                if (1...9998).contains(eventYear) { available.insert(eventYear) }
            }
        }
        available.insert(local.component(.year, from: now))
        let years = available.sorted(by: >)

        return ActivitySnapshot(
            year: year, years: years,
            savedCount: savedByDay.values.reduce(0, +),
            finishedCount: finishedByDay.values.reduce(0, +),
            unfinishedCount: library.links.filter { !$0.isArchived }.count,
            undatedFinishedCount: library.links.filter { $0.isArchived && $0.archiveHistory.isEmpty }.count,
            days: days, links: links, totalLinks: totalLinks, offset: offset, hasMore: hasMore
        )
    }

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = calendar.timeZone
        value.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        return value
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year; components.month = month; components.day = day
        return calendar.date(from: components)
    }

    private static func parse(day: String, year: Int, calendar: Calendar) -> Date? {
        let characters = Array(day)
        guard characters.count == 10, characters[4] == "-", characters[7] == "-" else { return nil }
        for (index, character) in characters.enumerated() where index != 4 && index != 7 {
            guard character.isASCII, character.isNumber else { return nil }
            _ = character
        }
        guard let parsedYear = Int(String(characters[0...3])),
              let month = Int(String(characters[5...6])),
              let parsedDay = Int(String(characters[8...9])),
              parsedYear == year, (1...12).contains(month), (1...31).contains(parsedDay),
              let date = date(year: parsedYear, month: month, day: parsedDay, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == parsedYear, parts.month == month, parts.day == parsedDay else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func isWithin(_ date: Date, from start: Date, to end: Date, now: Date) -> Bool {
        date >= start && date < end && date <= now
    }

    private static func dayString(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
