import Foundation
import SaveNestCore

/// No account/session, cookies, device ID, URL, or free-form event properties.
@MainActor
final class UsageAnalytics {
    private var accumulator = UsageAccumulator()
    private var timer: Timer?
    private var upload: Task<Void, Never>?
    private var uploadID: UUID?
    private var session: URLSession?
    private var enabled = false
    func configure(enabled requested: Bool) {
        let enabled = requested && !AppLaunch.isPreview && !AppRuntime.isPrivateBeta
        self.enabled = enabled
        accumulator.configure(enabled: enabled)
        timer?.invalidate(); timer = nil
        if !enabled {
            upload?.cancel(); upload = nil; uploadID = nil
            session?.invalidateAndCancel(); session = nil
            return
        }
        if session == nil {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCache = nil; config.timeoutIntervalForRequest = 10
            session = URLSession(configuration: config, delegate: AnalyticsRedirectBlocker(), delegateQueue: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flush() }
        }
    }
    func record(_ event: UsageEvent, count: Int = 1) {
        accumulator.record(event, count: count)
    }
    func flush() {
        guard enabled, upload == nil, let session, let batch = accumulator.drain() else { return }
        let id = UUID(); uploadID = id
        upload = Task {
            defer { if uploadID == id { upload = nil; uploadID = nil } }
            guard enabled, !Task.isCancelled else { return }
            var request = URLRequest(url: URL(string: "https://savenest.app/api/usage")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("SaveNest", forHTTPHeaderField: "User-Agent")
            request.httpBody = try? JSONEncoder().encode(batch)
            // Best effort, memory only: no offline history, background retries, or app-blocking errors.
            _ = try? await session.data(for: request)
        }
    }
    deinit { timer?.invalidate(); upload?.cancel(); session?.invalidateAndCancel() }
}

private final class AnalyticsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
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
