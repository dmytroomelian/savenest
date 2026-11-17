import Foundation

/// Best-effort, memory-only action counts. Both destinations share the same opt-out and preview boundary.
@MainActor
public final class UsageReporter {
    private var accumulator = UsageAccumulator()
    private var timer: Timer?
    private var upload: Task<Void, Never>?
    private var uploadID: UUID?
    private var session: URLSession?
    private var enabled = false
    private let isPreview: Bool
    private let postHog: PostHogUsageConfiguration?
    private let configuration: URLSessionConfiguration

    public init(postHog: PostHogUsageConfiguration? = nil, isPreview: Bool = false,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.postHog = postHog
        self.isPreview = isPreview
        configuration = sessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
    }

    public func configure(enabled requested: Bool) {
        enabled = requested && !isPreview
        accumulator.configure(enabled: enabled)
        timer?.invalidate(); timer = nil
        if !enabled {
            upload?.cancel(); upload = nil; uploadID = nil
            session?.invalidateAndCancel(); session = nil
            return
        }
        if session == nil {
            session = URLSession(configuration: configuration, delegate: AnalyticsRedirectBlocker(), delegateQueue: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flush() }
        }
    }

    public func record(_ event: UsageEvent, count: Int = 1) {
        accumulator.record(event, count: count)
    }

    public func flush() {
        guard enabled, upload == nil, let session, let batch = accumulator.drain(),
              let body = try? JSONEncoder().encode(batch) else { return }
        var primary = URLRequest(url: URL(string: "https://savenest.app/api/usage")!)
        primary.httpMethod = "POST"
        primary.httpShouldHandleCookies = false
        primary.setValue("application/json", forHTTPHeaderField: "Content-Type")
        primary.setValue("SaveNest", forHTTPHeaderField: "User-Agent")
        primary.httpBody = body
        var requests = [primary]
        if let request = try? postHog?.request(for: batch) { requests.append(request) }
        let id = UUID(); uploadID = id
        upload = Task {
            defer { if uploadID == id { upload = nil; uploadID = nil } }
            guard enabled, !Task.isCancelled else { return }
            // A slow or unavailable destination does not prevent delivery to the other one.
            await withTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        _ = try? await session.data(for: request)
                    }
                }
            }
        }
    }

    deinit { timer?.invalidate(); upload?.cancel(); session?.invalidateAndCancel() }
}

private final class AnalyticsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
