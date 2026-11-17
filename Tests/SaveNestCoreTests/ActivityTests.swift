import Foundation
import SaveNestCore

func runActivityChecks() throws {
    try checkArchiveHistoryCodingAndRoundTrips()
    checkArchiveTransitions()
    try checkActivityQuery()
    try checkActivityPagination()
    try checkActivityCalendarBoundaries()
    try checkActivityFutureEvents()
    try checkActivityValidation()
    try checkActivityEventFeed()
    try checkActivityEventPagination()
    try checkAutomationArchiveHistory()
    print("Passed activity and archive history checks")
}

private func activityCalendar(_ zone: String = "America/Los_Angeles") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func activityDate(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                          _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute, second: second))!
}

private func activityInstant(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

private func checkArchiveHistoryCodingAndRoundTrips() throws {
    var link = SavedLink(url: "https://example.com/history", title: "History")
    let t1 = Date(timeIntervalSince1970: 1_700_000_000.5)
    let t2 = Date(timeIntervalSince1970: 1_800_000_000)
    let emptyData = try JSONEncoder().encode(link)
    let emptyObject = try JSONSerialization.jsonObject(with: emptyData) as! [String: Any]
    XCTAssertNil(emptyObject["archiveHistory"])
    try XCTAssertEqual(try JSONDecoder().decode(SavedLink.self, from: emptyData).archiveHistory, [])

    var legacyObject = emptyObject
    legacyObject["isRead"] = true
    legacyObject["lastReadAt"] = "unknown legacy date"
    let legacy = try JSONDecoder().decode(SavedLink.self, from: JSONSerialization.data(withJSONObject: legacyObject))
    XCTAssertEqual(legacy.archiveHistory, [])
    XCTAssertEqual(legacy.url, link.url)
    XCTAssertFalse(String(data: try JSONEncoder().encode(legacy), encoding: .utf8)!.contains("lastReadAt"))

    link.archiveHistory = [t1, t2]
    let encoded = try JSONEncoder().encode(link)
    let roundTrip = try JSONDecoder().decode(SavedLink.self, from: encoded)
    XCTAssertEqual(roundTrip.archiveHistory, [t1, t2])
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    XCTAssertEqual((object["archiveHistory"] as! [Any]).count, 2)

    var library = Library()
    library.links = [link]
    var annotation = link
    annotation.id = link.id
    annotation.note = "Updated after archiving"
    annotation.archiveHistory = []
    XCTAssertTrue(library.saveAnnotated(annotation))
    XCTAssertEqual(library.links[0].archiveHistory, [t1, t2])
    XCTAssertEqual(library.links[0].note, "Updated after archiving")

    var imported = SavedLink(url: "https://example.com/imported", title: "Imported")
    imported.archiveHistory = [t1]
    XCTAssertEqual(library.insert([imported]), 1)
    XCTAssertEqual(library.links.first { $0.id == imported.id }?.archiveHistory, [t1])

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SaveNestActivity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = LibraryFile(url: directory.appendingPathComponent("library.json"))
    try file.save(library)
    try XCTAssertEqual(try file.load(), library)

    let device = UUID()
    let snapshot = CloudLibrarySnapshot(library: library, deviceId: device, createdAt: t1)
    let cloudBytes = try snapshot.encoded()
    let cloud = try CloudLibrarySnapshot.decode(cloudBytes)
    XCTAssertEqual(cloud.library.links.first { $0.id == link.id }?.archiveHistory, [t1, t2])
    let cloudObject = try JSONSerialization.jsonObject(with: cloudBytes) as! [String: Any]
    let cloudLibrary = cloudObject["library"] as! [String: Any]
    let cloudLinks = cloudLibrary["links"] as! [[String: Any]]
    XCTAssertTrue(cloudLinks.contains { ($0["archiveHistory"] as? [Any])?.count == 2 })

    var preEpoch = library
    preEpoch.links[0].archiveHistory = [Date(timeIntervalSince1970: -1), t2]
    let oldSnapshot = CloudLibrarySnapshot(library: preEpoch, deviceId: device, createdAt: t1)
    try XCTAssertEqual(try CloudLibrarySnapshot.decode(try oldSnapshot.encoded()).library.links[0].archiveHistory,
                   preEpoch.links[0].archiveHistory)

    var invalid = library
    invalid.links[0].archiveHistory = [Date(timeIntervalSince1970: 300_000_000_000)]
    XCTAssertThrowsError(try CloudLibrarySnapshot(library: invalid, deviceId: device).encoded())

    var malformed = cloudObject
    var malformedLibrary = malformed["library"] as! [String: Any]
    var malformedLinks = malformedLibrary["links"] as! [[String: Any]]
    malformedLinks[0]["archiveHistory"] = ["not-a-date"]
    malformedLibrary["links"] = malformedLinks
    malformed["library"] = malformedLibrary
    XCTAssertThrowsError(try CloudLibrarySnapshot.decode(JSONSerialization.data(withJSONObject: malformed)))
}

private func checkArchiveTransitions() {
    let calendar = activityCalendar()
    let t1 = activityDate(calendar, 2024, 3, 1, 9)
    let t2 = activityDate(calendar, 2024, 3, 2, 10)
    let t3 = activityDate(calendar, 2024, 3, 3, 11)

    var library = Library()
    let link = SavedLink(url: "https://example.com/transitions", title: "Transitions")
    library.links = [link]

    XCTAssertEqual(library.setArchived(false, ids: [link.id], at: t1), [])
    XCTAssertEqual(library.links[0].archiveHistory, [])
    XCTAssertEqual(library.setArchived(true, ids: [link.id], at: t1), [link.id])
    XCTAssertEqual(library.links[0].archiveHistory, [t1])
    XCTAssertTrue(library.links[0].isArchived)
    XCTAssertEqual(library.setArchived(true, ids: [link.id], at: t2), [])
    XCTAssertEqual(library.links[0].archiveHistory, [t1])
    XCTAssertEqual(library.setArchived(false, ids: [link.id], at: t2), [link.id])
    XCTAssertEqual(library.links[0].archiveHistory, [t1])
    XCTAssertFalse(library.links[0].isArchived)
    XCTAssertEqual(library.setArchived(false, ids: [link.id], at: t3), [])
    XCTAssertEqual(library.links[0].archiveHistory, [t1])
    XCTAssertEqual(library.setArchived(true, ids: [link.id], at: t3), [link.id])
    XCTAssertEqual(library.links[0].archiveHistory, [t1, t3])

    var direct = link
    direct.isArchived = false
    direct.archiveHistory = []
    Library.applyArchiveTransition(true, to: &direct, at: t1)
    Library.applyArchiveTransition(true, to: &direct, at: t2)
    Library.applyArchiveTransition(false, to: &direct, at: t2)
    Library.applyArchiveTransition(true, to: &direct, at: t3)
    XCTAssertEqual(direct.archiveHistory, [t1, t3])
}

private func checkActivityQuery() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2026, 6, 15, 12)
    var restored = SavedLink(url: "https://example.com/restored", title: "Restored")
    restored.createdAt = activityDate(calendar, 2026, 6, 10, 9)
    restored.archiveHistory = [
        activityDate(calendar, 2026, 6, 10, 10),
        activityDate(calendar, 2026, 6, 10, 18),
        activityDate(calendar, 2026, 6, 11, 8)
    ]
    restored.isArchived = false
    var boundary = SavedLink(url: "https://example.com/boundary", title: "Boundary")
    boundary.createdAt = activityDate(calendar, 2025, 12, 31, 23, 30)
    boundary.archiveHistory = [activityDate(calendar, 2026, 1, 1, 0, 10)]
    boundary.isArchived = true
    var undated = SavedLink(url: "https://example.com/undated", title: "Undated")
    undated.createdAt = activityDate(calendar, 2026, 1, 2, 12)
    undated.isArchived = true
    var finished = SavedLink(url: "https://example.com/finished", title: "Finished")
    finished.createdAt = activityDate(calendar, 2026, 6, 12, 9)
    finished.archiveHistory = [activityDate(calendar, 2026, 6, 12, 12)]
    finished.isArchived = true
    var future = SavedLink(url: "https://example.com/future", title: "Future")
    future.createdAt = activityDate(calendar, 2026, 7, 1, 9)
    future.archiveHistory = [activityDate(calendar, 2026, 6, 15, 13)]
    future.isArchived = false
    var library = Library()
    library.links = [restored, boundary, undated, finished, future]

    let snapshot = try LibraryActivity.query(library: library, year: 2026, calendar: calendar, now: now)
    XCTAssertEqual(snapshot.year, 2026)
    XCTAssertEqual(snapshot.years, [2026, 2025])
    XCTAssertEqual(snapshot.savedCount, 3)
    XCTAssertEqual(snapshot.finishedCount, 4)
    XCTAssertEqual(snapshot.unfinishedCount, 2)
    XCTAssertEqual(snapshot.undatedFinishedCount, 1)
    XCTAssertEqual(snapshot.days.count, 365)
    XCTAssertEqual(snapshot.days.first?.date, "2026-01-01")
    XCTAssertEqual(snapshot.days.last?.date, "2026-12-31")
    XCTAssertEqual(snapshot.links, [])
    XCTAssertEqual(snapshot.totalLinks, 0)
    XCTAssertFalse(snapshot.hasMore)

    let june10 = snapshot.days.first { $0.date == "2026-06-10" }!
    XCTAssertEqual(june10.saved, 1)
    XCTAssertEqual(june10.finished, 1)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-06-11" }?.finished, 1)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-01-01" }?.finished, 1)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-07-01" }?.saved, 0)

    let sameDay = try LibraryActivity.query(library: library, year: 2026, kind: "finished",
                                            day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(sameDay.links.count, 1)
    XCTAssertEqual(sameDay.links[0].id, restored.id.uuidString)
    XCTAssertEqual(sameDay.links[0].action, "finished")
    XCTAssertFalse(sameDay.links[0].saved)
    XCTAssertTrue(sameDay.links[0].finished)
    XCTAssertEqual(sameDay.links[0].eventID, "\(restored.id.uuidString):finished:2026-06-10")
    XCTAssertEqual(activityInstant(sameDay.links[0].occurredAt),
                   activityDate(calendar, 2026, 6, 10, 18))
    XCTAssertEqual(sameDay.totalLinks, 1)
    XCTAssertEqual(sameDay.finishedCount, 4)
    XCTAssertEqual(sameDay.savedCount, 3)

    let allSameDay = try LibraryActivity.query(library: library, year: 2026,
                                               day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(allSameDay.totalLinks, 2)
    XCTAssertEqual(allSameDay.links.map(\.action), ["finished", "saved"])
    XCTAssertEqual(Set(allSameDay.links.map(\.eventID)).count, 2)
    XCTAssertEqual(allSameDay.links.filter(\.saved).count, 1)
    XCTAssertEqual(allSameDay.links.filter(\.finished).count, 1)
    let savedEvent = allSameDay.links.first { $0.action == "saved" }!
    let finishedEvent = allSameDay.links.first { $0.action == "finished" }!
    XCTAssertEqual(activityInstant(savedEvent.occurredAt), restored.createdAt)
    XCTAssertEqual(activityInstant(finishedEvent.occurredAt),
                   activityDate(calendar, 2026, 6, 10, 18))
    XCTAssertEqual(savedEvent.eventID, "\(restored.id.uuidString):saved")
    XCTAssertEqual(finishedEvent.eventID, "\(restored.id.uuidString):finished:2026-06-10")

    let nextDay = try LibraryActivity.query(library: library, year: 2026, kind: "finished",
                                            day: "2026-06-11", calendar: calendar, now: now)
    XCTAssertEqual(nextDay.links.map(\.id), [restored.id.uuidString])
    XCTAssertEqual(nextDay.links[0].action, "finished")
    XCTAssertFalse(nextDay.links[0].saved)
    XCTAssertTrue(nextDay.links[0].finished)
    let notSaved = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                             day: "2026-06-11", calendar: calendar, now: now)
    XCTAssertEqual(notSaved.links, [])
    let savedOnly = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                              day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(savedOnly.links.map(\.id), [restored.id.uuidString])
    XCTAssertEqual(savedOnly.links[0].action, "saved")
    XCTAssertTrue(savedOnly.links[0].saved)
    XCTAssertFalse(savedOnly.links[0].finished)
    XCTAssertEqual(activityInstant(savedOnly.links[0].occurredAt), restored.createdAt)

    let encoded = try JSONEncoder().encode(snapshot)
    try XCTAssertEqual(try JSONDecoder().decode(ActivitySnapshot.self, from: encoded), snapshot)

    var deleted = library
    deleted.links.removeAll { $0.id == restored.id }
    let afterDelete = try LibraryActivity.query(library: deleted, year: 2026, kind: "finished",
                                                day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(afterDelete.days.first { $0.date == "2026-06-10" }?.finished, 0)
    XCTAssertEqual(afterDelete.finishedCount, 2)
    XCTAssertEqual(afterDelete.links, [])
}

private func checkActivityPagination() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2026, 6, 15, 12)
    let created = activityDate(calendar, 2026, 5, 1, 9)
    var library = Library()
    library.links = (0..<250).map { index in
        var link = SavedLink(url: "https://example.com/page/\(index)", title: "Page \(index)")
        link.createdAt = created
        return link
    }
    let first = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                          day: "2026-05-01", calendar: calendar, now: now)
    XCTAssertEqual(first.totalLinks, 250)
    XCTAssertEqual(first.links.count, 100)
    XCTAssertTrue(first.hasMore)
    XCTAssertEqual(first.offset, 0)
    let expected = library.links.map(\.id.uuidString).sorted()
    XCTAssertEqual(first.links.map(\.id), Array(expected.prefix(100)))

    let second = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                           day: "2026-05-01", offset: 100,
                                           calendar: calendar, now: now)
    XCTAssertEqual(second.links.count, 100)
    XCTAssertTrue(second.hasMore)
    XCTAssertEqual(second.links.map(\.id), Array(expected[100..<200]))
    let third = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                          day: "2026-05-01", offset: 200,
                                          calendar: calendar, now: now)
    XCTAssertEqual(third.links.count, 50)
    XCTAssertFalse(third.hasMore)
    XCTAssertEqual(third.links.map(\.id), Array(expected[200..<250]))
    let empty = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                          day: "2026-05-01", offset: 250,
                                          calendar: calendar, now: now)
    XCTAssertEqual(empty.links, [])
    XCTAssertFalse(empty.hasMore)
    try XCTAssertEqual(first.links.map(\.id), try LibraryActivity.query(
        library: library, year: 2026, kind: "saved", day: "2026-05-01",
        calendar: calendar, now: now).links.map(\.id))
    XCTAssertTrue(Set(first.links.map(\.id)).isDisjoint(with: Set(second.links.map(\.id))))

    let all = try LibraryActivity.query(library: library, year: 2026, calendar: calendar, now: now)
    XCTAssertEqual(all.savedCount, 250)
    XCTAssertEqual(all.days.first { $0.date == "2026-05-01" }?.saved, 250)
}

private func checkActivityCalendarBoundaries() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2027, 1, 15, 12)
    var midnight = SavedLink(url: "https://example.com/midnight", title: "Midnight")
    midnight.createdAt = activityDate(calendar, 2024, 1, 1, 0, 0)
    var leap = SavedLink(url: "https://example.com/leap", title: "Leap")
    leap.createdAt = activityDate(calendar, 2024, 2, 29, 12)
    var end = SavedLink(url: "https://example.com/end", title: "End")
    end.createdAt = activityDate(calendar, 2024, 12, 31, 23, 30)
    var previous = SavedLink(url: "https://example.com/previous", title: "Previous")
    previous.createdAt = activityDate(calendar, 2023, 12, 31, 23, 59)
    var next = SavedLink(url: "https://example.com/next", title: "Next")
    next.createdAt = activityDate(calendar, 2025, 1, 1, 0, 0)
    var spring = SavedLink(url: "https://example.com/spring", title: "Spring")
    spring.createdAt = activityDate(calendar, 2026, 3, 8, 0, 15)
    var springLate = SavedLink(url: "https://example.com/spring-late", title: "Spring late")
    springLate.createdAt = activityDate(calendar, 2026, 3, 8, 23, 45)
    var springNext = SavedLink(url: "https://example.com/spring-next", title: "Spring next")
    springNext.createdAt = activityDate(calendar, 2026, 3, 9, 0, 30)
    var fall = SavedLink(url: "https://example.com/fall", title: "Fall")
    fall.createdAt = activityDate(calendar, 2026, 11, 1, 0, 30)
    var fallLate = SavedLink(url: "https://example.com/fall-late", title: "Fall late")
    fallLate.createdAt = activityDate(calendar, 2026, 11, 1, 23, 30)
    var library = Library()
    library.links = [midnight, leap, end, previous, next, spring, springLate, springNext, fall, fallLate]

    let leapYear = try LibraryActivity.query(library: library, year: 2024, calendar: calendar, now: now)
    XCTAssertEqual(leapYear.days.count, 366)
    XCTAssertEqual(leapYear.savedCount, 3)
    XCTAssertEqual(leapYear.days.first?.date, "2024-01-01")
    XCTAssertEqual(leapYear.days.last?.date, "2024-12-31")
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2024, kind: "saved",
                                             day: "2024-01-01", calendar: calendar, now: now).links.count, 1)
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2024, kind: "saved",
                                             day: "2024-02-29", calendar: calendar, now: now).links.count, 1)
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2024, kind: "saved",
                                             day: "2024-12-31", calendar: calendar, now: now).links.count, 1)
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2025, calendar: calendar, now: now).savedCount, 1)
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2023, calendar: calendar, now: now).savedCount, 1)
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2025, calendar: calendar,
                                             now: now).days.count, 365)

    let springDay = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                              day: "2026-03-08", calendar: calendar, now: now)
    XCTAssertEqual(springDay.links.map(\.title).sorted(), ["Spring", "Spring late"])
    let springNextDay = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                                  day: "2026-03-09", calendar: calendar, now: now)
    XCTAssertEqual(springNextDay.links.map(\.title), ["Spring next"])
    let fallDay = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                            day: "2026-11-01", calendar: calendar, now: now)
    XCTAssertEqual(fallDay.links.map(\.title).sorted(), ["Fall", "Fall late"])
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2026, calendar: calendar,
                                             now: now).savedCount, 5)
}

private func checkActivityFutureEvents() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2026, 6, 15, 12)
    var today = SavedLink(url: "https://example.com/today", title: "Today")
    today.createdAt = activityDate(calendar, 2026, 6, 15, 9)
    today.archiveHistory = [
        activityDate(calendar, 2026, 6, 15, 13),
        activityDate(calendar, 2026, 6, 10, 10)
    ]
    today.isArchived = false
    var future = SavedLink(url: "https://example.com/tomorrow", title: "Tomorrow")
    future.createdAt = activityDate(calendar, 2026, 6, 20, 9)
    future.archiveHistory = [activityDate(calendar, 2026, 6, 20, 10)]
    var library = Library()
    library.links = [today, future]

    let snapshot = try LibraryActivity.query(library: library, year: 2026, calendar: calendar, now: now)
    XCTAssertEqual(snapshot.savedCount, 1)
    XCTAssertEqual(snapshot.finishedCount, 1)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-06-15" }?.saved, 1)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-06-15" }?.finished, 0)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-06-20" }?.saved, 0)
    XCTAssertEqual(snapshot.days.first { $0.date == "2026-06-10" }?.finished, 1)

    let todayLinks = try LibraryActivity.query(library: library, year: 2026, kind: "finished",
                                               day: "2026-06-15", calendar: calendar, now: now)
    XCTAssertEqual(todayLinks.links, [])
    XCTAssertThrowsError(try LibraryActivity.query(library: library, year: 2026,
                                                   day: "2026-06-16", calendar: calendar, now: now))
    XCTAssertThrowsError(try LibraryActivity.query(library: library, year: 2026,
                                                   day: "2026-06-20", calendar: calendar, now: now))
}

private func checkActivityValidation() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2026, 6, 15, 12)
    var library = Library()
    library.links = [SavedLink(url: "https://example.com/valid", title: "Valid")]

    for year in [0, -1, 9999, 10_000] {
        XCTAssertThrowsError(try LibraryActivity.query(library: library, year: year, calendar: calendar, now: now))
    }
    XCTAssertThrowsError(try LibraryActivity.query(library: library, year: 2026, kind: "read",
                                                   calendar: calendar, now: now))
    for day in ["2026-1-01", "2026-01-1", "2026-02-30", "2026-13-01", "2026-00-10",
                "2026-01-32", "2025-12-31", "2026/01/01", "2026-01-01x", "abcd-ef-gh"] {
        XCTAssertThrowsError(try LibraryActivity.query(library: library, year: 2026, day: day,
                                                       calendar: calendar, now: now))
    }
    XCTAssertThrowsError(try LibraryActivity.query(library: library, year: 2026,
                                                   offset: -1, calendar: calendar, now: now))
    for limit in [0, -1, 101] {
        XCTAssertThrowsError(try LibraryActivity.query(library: library, year: 2026,
                                                       limit: limit, calendar: calendar, now: now))
    }
    try XCTAssertEqual(try LibraryActivity.query(library: library, year: 2026, kind: "ALL",
                                             limit: 1, calendar: calendar, now: now).days.count, 365)
}

private func checkActivityEventFeed() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2026, 6, 15, 12)

    var both = SavedLink(url: "https://example.com/both", title: "Both")
    both.createdAt = activityDate(calendar, 2026, 6, 10, 9)
    both.archiveHistory = [activityDate(calendar, 2026, 6, 10, 18)]
    var late = SavedLink(url: "https://example.com/late", title: "Late")
    late.createdAt = activityDate(calendar, 2026, 6, 10, 11)
    var before = SavedLink(url: "https://example.com/before", title: "Before")
    before.createdAt = activityDate(calendar, 2026, 6, 9, 9)
    before.archiveHistory = [activityDate(calendar, 2026, 6, 10, 10)]
    var early = SavedLink(url: "https://example.com/early", title: "Early")
    early.createdAt = activityDate(calendar, 2026, 6, 10, 8, 30)
    var repeated = SavedLink(url: "https://example.com/repeated", title: "Repeated")
    repeated.createdAt = activityDate(calendar, 2026, 6, 1, 9)
    repeated.archiveHistory = [
        activityDate(calendar, 2026, 6, 10, 10),
        activityDate(calendar, 2026, 6, 10, 18),
        activityDate(calendar, 2026, 6, 10, 12)
    ]
    var library = Library()
    library.links = [both, repeated, late, before, early]

    let all = try LibraryActivity.query(library: library, year: 2026,
                                       day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(all.totalLinks, 6)
    XCTAssertEqual(all.links.count, 6)
    XCTAssertEqual(Set(all.links.map(\.eventID)).count, 6)
    for event in all.links {
        XCTAssertTrue(event.saved != event.finished)
    }

    let bothEvents = all.links.filter { $0.id == both.id.uuidString }
    XCTAssertEqual(bothEvents.count, 2)
    XCTAssertEqual(Set(bothEvents.map(\.action)), ["saved", "finished"])
    XCTAssertEqual(Set(bothEvents.map(\.eventID)),
                   ["\(both.id.uuidString):saved", "\(both.id.uuidString):finished:2026-06-10"])
    let bothSaved = bothEvents.first { $0.action == "saved" }!
    let bothFinished = bothEvents.first { $0.action == "finished" }!
    XCTAssertEqual(activityInstant(bothSaved.occurredAt), both.createdAt)
    XCTAssertEqual(activityInstant(bothFinished.occurredAt), both.archiveHistory[0])
    XCTAssertTrue(bothSaved.occurredAt.hasSuffix("Z"))

    XCTAssertEqual(all.links[2].title, "Late")
    XCTAssertEqual(all.links[3].title, "Before")
    XCTAssertEqual(all.links[4].title, "Both")
    XCTAssertEqual(all.links[5].title, "Early")
    let finishing = all.links.filter {
        activityInstant($0.occurredAt) == activityDate(calendar, 2026, 6, 10, 18)
    }
    XCTAssertEqual(finishing.count, 2)
    XCTAssertEqual(finishing.map(\.eventID), finishing.map(\.eventID).sorted())
    for (lhs, rhs) in zip(all.links, all.links.dropFirst()) {
        let left = activityInstant(lhs.occurredAt)!
        let right = activityInstant(rhs.occurredAt)!
        XCTAssertTrue(left >= right)
    }

    let savedOnly = try LibraryActivity.query(library: library, year: 2026, kind: "saved",
                                              day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(savedOnly.links.map(\.action), ["saved", "saved", "saved"])
    XCTAssertTrue(savedOnly.links.allSatisfy { $0.saved && !$0.finished })
    let finishedOnly = try LibraryActivity.query(library: library, year: 2026, kind: "finished",
                                                 day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(finishedOnly.links.map(\.action), ["finished", "finished", "finished"])
    XCTAssertTrue(finishedOnly.links.allSatisfy { !$0.saved && $0.finished })

    let repeatedFinished = all.links.filter {
        $0.id == repeated.id.uuidString && $0.action == "finished"
    }
    XCTAssertEqual(repeatedFinished.count, 1)
    XCTAssertEqual(activityInstant(repeatedFinished[0].occurredAt),
                   activityDate(calendar, 2026, 6, 10, 18))
    XCTAssertEqual(all.days.first { $0.date == "2026-06-10" }?.finished, 3)
    XCTAssertEqual(all.days.first { $0.date == "2026-06-10" }?.saved, 3)

    var tieOne = SavedLink(url: "https://example.com/tie-one", title: "Tie one")
    tieOne.createdAt = activityDate(calendar, 2026, 6, 12, 9)
    var tieTwo = SavedLink(url: "https://example.com/tie-two", title: "Tie two")
    tieTwo.createdAt = activityDate(calendar, 2026, 6, 12, 9)
    var ties = Library()
    ties.links = [tieTwo, tieOne]
    let tieSnapshot = try LibraryActivity.query(library: ties, year: 2026, kind: "saved",
                                                day: "2026-06-12", calendar: calendar, now: now)
    XCTAssertEqual(tieSnapshot.links.map(\.eventID),
                   ["\(tieOne.id.uuidString):saved", "\(tieTwo.id.uuidString):saved"].sorted())
}

private func checkActivityEventPagination() throws {
    let calendar = activityCalendar()
    let now = activityDate(calendar, 2026, 6, 15, 12)
    var target = SavedLink(url: "https://example.com/target", title: "Target")
    target.createdAt = activityDate(calendar, 2026, 6, 10, 11, 58)
    target.archiveHistory = [activityDate(calendar, 2026, 6, 10, 11, 59)]
    var library = Library()
    library.links = [target] + (0..<99).map { index in
        var link = SavedLink(url: "https://example.com/filler/\(index)", title: "Filler \(index)")
        link.createdAt = activityDate(calendar, 2026, 6, 10, 12)
        return link
    }

    let first = try LibraryActivity.query(library: library, year: 2026,
                                          day: "2026-06-10", calendar: calendar, now: now)
    XCTAssertEqual(first.totalLinks, 101)
    XCTAssertEqual(first.links.count, 100)
    XCTAssertTrue(first.hasMore)
    XCTAssertEqual(first.links.last?.eventID,
                   "\(target.id.uuidString):finished:2026-06-10")
    XCTAssertEqual(first.links.last?.id, target.id.uuidString)

    let second = try LibraryActivity.query(library: library, year: 2026, day: "2026-06-10",
                                           offset: 100, calendar: calendar, now: now)
    XCTAssertEqual(second.totalLinks, 101)
    XCTAssertEqual(second.links.count, 1)
    XCTAssertFalse(second.hasMore)
    XCTAssertEqual(second.links[0].eventID, "\(target.id.uuidString):saved")
    XCTAssertEqual(second.links[0].id, target.id.uuidString)
    XCTAssertTrue(Set(first.links.map(\.eventID)).isDisjoint(with: Set(second.links.map { $0.eventID })))
    XCTAssertEqual(Set(first.links.map(\.eventID)).union(second.links.map { $0.eventID }).count, 101)
    XCTAssertEqual(first.links.filter { $0.id == target.id.uuidString }.count, 1)
}

private func checkAutomationArchiveHistory() throws {
    let calendar = activityCalendar()
    let t1 = activityDate(calendar, 2026, 6, 1, 9)
    let t2 = activityDate(calendar, 2026, 6, 2, 9)
    let t3 = activityDate(calendar, 2026, 6, 3, 9)
    let link = SavedLink(url: "https://example.com/automation", title: "Automation")
    var library = Library()
    library.links = [link]

    func update(_ archived: Bool, at date: Date, in library: Library) throws -> AutomationLibraryResult {
        let revision = AutomationLibrary.revision(library.links[0])
        return try AutomationLibrary.execute(tool: "update_links", arguments: [
            "items": .array([.object([
                "id": .string(link.id.uuidString),
                "revision": .string(revision),
                "archived": .bool(archived)
            ])])
        ], library: library, now: date)
    }

    let archived = try update(true, at: t1, in: library)
    XCTAssertTrue(archived.changed)
    XCTAssertEqual(archived.library.links[0].archiveHistory, [t1])
    XCTAssertTrue(archived.library.links[0].isArchived)
    XCTAssertEqual(archived.result["completed"]?.int, 1)

    let noop = try update(true, at: t2, in: archived.library)
    XCTAssertFalse(noop.changed)
    XCTAssertEqual(noop.library.links[0].archiveHistory, [t1])
    XCTAssertEqual(noop.result["skipped"]?.int, 1)

    let restored = try update(false, at: t2, in: noop.library)
    XCTAssertTrue(restored.changed)
    XCTAssertFalse(restored.library.links[0].isArchived)
    XCTAssertEqual(restored.library.links[0].archiveHistory, [t1])

    let rearchived = try update(true, at: t3, in: restored.library)
    XCTAssertTrue(rearchived.changed)
    XCTAssertTrue(rearchived.library.links[0].isArchived)
    XCTAssertEqual(rearchived.library.links[0].archiveHistory, [t1, t3])
    XCTAssertEqual(library.links[0].archiveHistory, [])

    let failed = try AutomationLibrary.execute(tool: "update_links", arguments: [
        "items": .array([.object([
            "id": .string(link.id.uuidString),
            "revision": .string(AutomationLibrary.revision(rearchived.library.links[0])),
            "archived": .bool(false),
            "unknown": .bool(true)
        ])])
    ], library: rearchived.library, now: t2)
    XCTAssertFalse(failed.changed)
    XCTAssertEqual(failed.library, rearchived.library)
    XCTAssertEqual(failed.result["failed"]?.int, 1)

    let snapshot = try LibraryActivity.query(library: rearchived.library, year: 2026,
                                             kind: "finished", day: "2026-06-03",
                                             calendar: calendar, now: activityDate(calendar, 2026, 6, 15, 12))
    XCTAssertEqual(snapshot.links.map(\.id), [link.id.uuidString])
    XCTAssertEqual(snapshot.links[0].action, "finished")
    XCTAssertEqual(snapshot.links[0].eventID, "\(link.id.uuidString):finished:2026-06-03")
    XCTAssertTrue(snapshot.links[0].finished)
    XCTAssertFalse(snapshot.links[0].saved)
}
