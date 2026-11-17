import Foundation
import SaveNestCore

@MainActor
func runUsageAnalyticsChecks() async throws {
    let token = "phc_" + String(repeating: "a", count: 40)
    let configuration = PostHogUsageConfiguration(projectToken: token, host: "https://eu.i.posthog.com")!
    XCTAssertEqual(configuration.endpoint.absoluteString, "https://eu.i.posthog.com/batch/")
    XCTAssertEqual(PostHogUsageConfiguration(projectToken: token, host: "https://us.i.posthog.com/")?.endpoint.absoluteString,
                   "https://us.i.posthog.com/batch/")
    for host in ["", "http://eu.i.posthog.com", "https://eu.posthog.com", "https://eu.i.posthog.com.evil.test",
                 "https://eu.i.posthog.com:443", "https://eu.i.posthog.com/path", "https://eu.i.posthog.com?key=secret",
                 "https://user@eu.i.posthog.com", "https://eu.i.posthog.com/#fragment"] {
        XCTAssertNil(PostHogUsageConfiguration(projectToken: token, host: host), host)
    }
    for invalidToken in ["", "phc_", "phx_" + String(repeating: "a", count: 40), "phc_your_project_token",
                         token + "\n", token + "é", "phc_" + String(repeating: "a", count: 201)] {
        XCTAssertNil(PostHogUsageConfiguration(projectToken: invalidToken, host: "https://eu.i.posthog.com"))
    }
    XCTAssertNil(PostHogUsageConfiguration(projectToken: nil, host: nil))

    let batch = UsageBatch(counts: Dictionary(uniqueKeysWithValues: UsageEvent.allCases.map { ($0, 3) }))
    let request = try configuration.request(for: batch)!
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SaveNest")
    let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    XCTAssertEqual(Set(object.keys), Set(["api_key", "batch"]))
    XCTAssertEqual(object["api_key"] as? String, token)
    let events = object["batch"] as! [[String: Any]]
    let expectedNames: Set<String> = ["app_opened", "links_saved", "clipboard_saved", "note_saved", "tags_saved",
                                    "link_opened", "link_copied", "links_archived", "importance_labeled"]
    XCTAssertEqual(Set(events.compactMap { $0["event"] as? String }), expectedNames)
    for event in events {
        XCTAssertEqual(Set(event.keys), Set(["event", "distinct_id", "properties"]))
        XCTAssertEqual(event["distinct_id"] as? String, batch.batchID.uuidString)
        let properties = event["properties"] as! [String: Any]
        XCTAssertEqual(Set(properties.keys), Set(["count", "surface", "$process_person_profile", "$geoip_disable", "$ip"]))
        XCTAssertEqual(properties["count"] as? Int, 3)
        XCTAssertEqual(properties["surface"] as? String, "mac")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertEqual(properties["$ip"] as? String, "0.0.0.0")
    }
    let another = UsageBatch(counts: [.appOpened: 1])
    XCTAssertFalse(another.batchID == batch.batchID)
    XCTAssertNil(try configuration.request(for: UsageBatch(counts: [:])))

    // A decoded batch can contain arbitrary strings and counts; none may escape the typed boundary.
    let hostileJSON: [String: Any] = ["batchID": batch.batchID.uuidString, "counts": [
        "https://private.test/saved-page": 1, "account@example.test": 2,
        "links_saved": Int.max, "note_saved": -2, "tags_saved": 0]]
    let hostile = try JSONDecoder().decode(UsageBatch.self, from: JSONSerialization.data(withJSONObject: hostileJSON))
    let filteredRequest = try configuration.request(for: hostile)!
    let filtered = try JSONSerialization.jsonObject(with: filteredRequest.httpBody!) as! [String: Any]
    let filteredEvents = filtered["batch"] as! [[String: Any]]
    XCTAssertEqual(filteredEvents.count, 1)
    XCTAssertEqual(filteredEvents[0]["event"] as? String, "links_saved")
    XCTAssertEqual((filteredEvents[0]["properties"] as? [String: Any])?["count"] as? Int, 1000)

    try await checkUsageReporterRuntime(postHog: configuration)
    print("Passed PostHog payload, configuration, preview, opt-out, cancellation, and delivery checks")
}

@MainActor
private func checkUsageReporterRuntime(postHog: PostHogUsageConfiguration) async throws {
    let capture = AnalyticsTestProtocol.capture
    func reporter(postHog: PostHogUsageConfiguration? = nil, preview: Bool = false) -> UsageReporter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsTestProtocol.self]
        return UsageReporter(postHog: postHog, isPreview: preview, sessionConfiguration: configuration)
    }

    capture.reset(mode: .success)
    let preview = reporter(postHog: postHog, preview: true)
    preview.configure(enabled: true)
    preview.record(.appOpened)
    preview.flush()
    await settleUsageTasks()
    XCTAssertTrue(capture.requests.isEmpty)
    preview.configure(enabled: false)

    // No PostHog configuration preserves the original backend and its exact payload.
    capture.reset(mode: .success)
    let unconfigured = reporter()
    unconfigured.record(.appOpened)
    unconfigured.flush()
    await settleUsageTasks()
    XCTAssertTrue(capture.requests.isEmpty)
    unconfigured.configure(enabled: true)
    unconfigured.record(.linksSaved, count: 2)
    unconfigured.flush()
    await eventuallyUsage { capture.finished == 1 }
    XCTAssertEqual(capture.requests.map { $0.url?.absoluteString }, ["https://savenest.app/api/usage"])
    let legacyBody = try JSONSerialization.jsonObject(with: capture.bodies[0]) as! [String: Any]
    XCTAssertEqual(Set(legacyBody.keys), Set(["batchID", "counts"]))
    XCTAssertEqual(legacyBody["counts"] as? [String: Int], ["links_saved": 2])
    unconfigured.configure(enabled: false)

    // A failed backend request does not prevent the independently started PostHog upload.
    capture.reset(mode: .failPrimary)
    let independent = reporter(postHog: postHog)
    independent.configure(enabled: true)
    independent.record(.linkOpened)
    independent.flush()
    independent.flush()
    await eventuallyUsage { capture.finished == 2 }
    XCTAssertEqual(Set(capture.requests.compactMap { $0.url?.host }), Set(["savenest.app", "eu.i.posthog.com"]))
    XCTAssertEqual(capture.requests.count, 2)
    independent.configure(enabled: false)

    // Opt-out before task scheduling prevents both requests from starting.
    capture.reset(mode: .hold)
    let earlyOptOut = reporter(postHog: postHog)
    earlyOptOut.configure(enabled: true)
    earlyOptOut.record(.appOpened)
    earlyOptOut.flush()
    earlyOptOut.configure(enabled: false)
    await settleUsageTasks()
    XCTAssertTrue(capture.requests.isEmpty)

    // Opt-out cancels both in-flight requests and discards counts waiting behind them.
    capture.reset(mode: .hold)
    let cancellable = reporter(postHog: postHog)
    cancellable.configure(enabled: true)
    cancellable.record(.appOpened)
    cancellable.flush()
    await eventuallyUsage { capture.requests.count == 2 }
    cancellable.record(.linksSaved, count: 8)
    cancellable.configure(enabled: false)
    await eventuallyUsage { capture.cancelled == 2 }
    cancellable.configure(enabled: true)
    cancellable.flush()
    await settleUsageTasks()
    XCTAssertEqual(capture.requests.count, 2)
    cancellable.record(.linkCopied)
    cancellable.flush()
    await eventuallyUsage { capture.requests.count == 4 }
    let freshBodies = capture.bodies.suffix(2)
    XCTAssertTrue(freshBodies.allSatisfy { String(data: $0, encoding: .utf8)!.contains("link_copied") })
    XCTAssertFalse(freshBodies.contains { String(data: $0, encoding: .utf8)!.contains("links_saved") })
    cancellable.configure(enabled: false)
    await eventuallyUsage { capture.cancelled == 4 }
}

@MainActor
private func eventuallyUsage(_ condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    preconditionFailure("Analytics test timed out")
}

@MainActor
private func settleUsageTasks() async {
    for _ in 0..<10 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
}

private final class AnalyticsTestProtocol: URLProtocol {
    static let capture = AnalyticsRequestCapture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.capture.start(request)
        if mode == .hold { return }
        if mode == .failPrimary && request.url?.host == "savenest.app" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        Self.capture.finish()
    }
    override func stopLoading() { Self.capture.cancel() }
}

private final class AnalyticsRequestCapture {
    enum Mode { case success, failPrimary, hold }
    private let lock = NSLock()
    private var mode = Mode.success
    private var storedRequests: [URLRequest] = []
    private var storedBodies: [Data] = []
    private var completed = 0
    private var stopped = 0
    var requests: [URLRequest] { lock.withLock { storedRequests } }
    var bodies: [Data] { lock.withLock { storedBodies } }
    var finished: Int { lock.withLock { completed } }
    var cancelled: Int { lock.withLock { stopped } }
    func reset(mode: Mode) {
        lock.withLock {
            self.mode = mode; storedRequests = []; storedBodies = []; completed = 0; stopped = 0
        }
    }
    func start(_ request: URLRequest) -> Mode {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        return lock.withLock {
            storedRequests.append(request); storedBodies.append(body); return mode
        }
    }
    func finish() { lock.withLock { completed += 1 } }
    func cancel() { lock.withLock { stopped += 1 } }
}
