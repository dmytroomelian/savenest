import Foundation
import SaveNestCore

/// No account/session, cookies, device ID, URL, or free-form event properties.
@MainActor
final class UsageAnalytics {
    private static let postHogConfiguration = PostHogUsageConfiguration(
        projectToken: Bundle.main.object(forInfoDictionaryKey: "SaveNestPostHogProjectToken") as? String,
        host: Bundle.main.object(forInfoDictionaryKey: "SaveNestPostHogHost") as? String)

    static var sharingDescription: String {
        let services = postHogConfiguration == nil ? "Savenest" : "Savenest and PostHog"
        return "Share anonymous action counts with \(services). No URLs, titles, notes, tags, account IDs, or device identifiers are included."
    }

    private let reporter = UsageReporter(
        postHog: UsageAnalytics.postHogConfiguration,
        isPreview: AppLaunch.isPreview || AppRuntime.isPrivateBeta)

    func configure(enabled requested: Bool) {
        reporter.configure(enabled: requested)
    }
    func record(_ event: UsageEvent, count: Int = 1) {
        reporter.record(event, count: count)
    }
    func flush() { reporter.flush() }
}

struct UsageReport: Decodable {
    struct Row: Decodable, Identifiable {
        let day: String
        let event: String
        let count: Int
        var id: String { day + event }
    }
    let days: Int
    let rows: [Row]
}
