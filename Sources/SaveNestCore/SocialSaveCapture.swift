import Foundation

/// A single user-initiated save observed through macOS Accessibility.
public struct SocialSaveCapture: Codable, Equatable {
    public var version = 1
    public let platform: String
    public let url: String
    public let title: String
    public let note: String
    public let observedAt: String
    public let eventId: String
    public let evidence: String

    public init(platform: String, url: String, title: String, note: String, observedAt: String, eventId: String, evidence: String) {
        self.platform = platform
        self.url = url
        self.title = title
        self.note = note
        self.observedAt = observedAt
        self.eventId = eventId
        self.evidence = evidence
    }

    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    public func validated() throws -> SocialSaveCapture {
        guard version == 1, ["x", "linkedin", "slack"].contains(platform),
              title.count <= 500, note.count <= 20_000, !eventId.isEmpty, eventId.count <= 128,
              Self.date(observedAt) != nil,
              ["saved-ui", "accessibility-state-change"].contains(evidence),
              let parts = URLComponents(string: url), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), parts.fragment == nil else {
            throw SocialSaveCaptureError("Invalid capture payload")
        }
        let pattern: String
        switch platform {
        case "x":
            guard ["x.com", "twitter.com", "www.x.com", "www.twitter.com"].contains(host) else { throw SocialSaveCaptureError("Invalid X host") }
            pattern = "^/(?:[A-Za-z0-9_]+/status|i/web/status)/[0-9]+/?$"
        case "linkedin":
            guard ["linkedin.com", "www.linkedin.com", "lnkd.in"].contains(host) else { throw SocialSaveCaptureError("Invalid LinkedIn host") }
            pattern = host == "lnkd.in" ? "^/p/[A-Za-z0-9_-]{4,80}/?$" : "^/(?:feed/update/urn:li:(?:activity|share|ugcPost):[0-9]+/?|posts/[^/]+-activity-[0-9]+-[^/]+/?)$"
        default:
            guard host.hasSuffix(".slack.com"), host != "app.slack.com" else { throw SocialSaveCaptureError("Invalid Slack host") }
            pattern = "^/archives/[A-Za-z0-9]+/p[0-9]+/?$"
        }
        guard parts.path.range(of: pattern, options: .regularExpression) != nil else { throw SocialSaveCaptureError("Expected a post or message permalink") }
        return self
    }
}

public struct SocialSaveCaptureError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
