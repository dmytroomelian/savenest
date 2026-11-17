import Foundation

/// Public, write-only project configuration. An absent or invalid configuration disables this destination.
public struct PostHogUsageConfiguration {
    private let projectToken: String
    public let endpoint: URL

    public init?(projectToken: String?, host: String?) {
        guard let projectToken, let host,
              projectToken.hasPrefix("phc_"),
              (16...200).contains(projectToken.dropFirst(4).utf8.count),
              projectToken.dropFirst(4).utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
              }) else { return nil }
        let hosts = ["https://eu.i.posthog.com", "https://us.i.posthog.com"]
        guard let origin = hosts.first(where: { host == $0 || host == $0 + "/" }),
              let endpoint = URL(string: origin + "/batch/") else { return nil }
        self.projectToken = projectToken
        self.endpoint = endpoint
    }

    /// No caller-supplied property dictionary or persistent identity can enter this payload.
    public func request(for batch: UsageBatch) throws -> URLRequest? {
        let events = UsageEvent.allCases.compactMap { event -> PostHogUsageEvent? in
            guard let count = batch.counts[event.rawValue], count > 0 else { return nil }
            return PostHogUsageEvent(event: event.rawValue, distinctID: batch.batchID.uuidString,
                                     properties: PostHogUsageProperties(count: min(count, 1000)))
        }
        guard !events.isEmpty else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SaveNest", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(PostHogUsagePayload(apiKey: projectToken, batch: events))
        return request
    }
}

private struct PostHogUsagePayload: Encodable {
    let apiKey: String
    let batch: [PostHogUsageEvent]
    enum CodingKeys: String, CodingKey { case apiKey = "api_key", batch }
}

private struct PostHogUsageEvent: Encodable {
    let event: String
    let distinctID: String
    let properties: PostHogUsageProperties
    enum CodingKeys: String, CodingKey { case event, distinctID = "distinct_id", properties }
}

private struct PostHogUsageProperties: Encodable {
    let count: Int
    let surface = "mac"
    let processPersonProfile = false
    let disableGeoIP = true
    // A nonempty placeholder prevents ingestion from substituting the connection IP into event properties.
    // PostHog still receives the connection IP at its network boundary.
    let ip = "0.0.0.0"
    enum CodingKeys: String, CodingKey {
        case count, surface, processPersonProfile = "$process_person_profile", disableGeoIP = "$geoip_disable", ip = "$ip"
    }
}
