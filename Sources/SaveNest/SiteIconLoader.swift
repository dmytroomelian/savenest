import AppKit
import CryptoKit
import ImageIO
import SaveNestCore

/// Fetch directly from the site without browser cookies, credentials, or a favicon proxy.
actor SiteIconLoader {
    static let shared = SiteIconLoader()
    private struct Entry { let data: Data?; let expires: Date }
    private var cache: [String: Entry] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let directory: URL
    private let session: URLSession

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(AppRuntime.isPrivateBeta ? "app.savenest.aws-beta/SiteIcons" : "app.savenest.mac/SiteIcons")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func image(page: String, hint: String?) async -> Data? {
        guard let origin = SiteIcon.origin(page) else { return nil }
        let explicit = SiteIcon.resolve(hint, relativeTo: origin)
        let key = SHA256.hash(data: Data((origin.absoluteString + "|" + (explicit?.absoluteString ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
        if let entry = cache[key], entry.expires > Date() { return entry.data }
        if let task = pending[key] { return await task.value }
        let task = Task { await self.load(origin: origin, explicit: explicit, key: key) }
        pending[key] = task
        let data = await task.value
        pending[key] = nil
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = Entry(data: data, expires: Date().addingTimeInterval(data == nil ? 3600 : 604800))
        return data
    }

    private func load(origin: URL, explicit: URL?, key: String) async -> Data? {
        let file = directory.appendingPathComponent(key + ".png")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 604800,
           let data = try? Data(contentsOf: file), data.count <= 1_048_576 { return data }
        if activeLoads >= 6 { await withCheckedContinuation { waiters.append($0) } }
        else { activeLoads += 1 }
        defer {
            if waiters.isEmpty { activeLoads -= 1 }
            else { waiters.removeFirst().resume() }
        }
        var tried = Set<URL>()
        func candidate(_ url: URL) async -> Data? {
            guard tried.insert(url).inserted, let (bytes, _) = await fetch(url, limit: 1_048_576),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 84,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        var result: Data?
        if let explicit { result = await candidate(explicit) }
        if result == nil { result = await candidate(origin.appendingPathComponent("favicon.ico")) }
        // Older saves have no DOM metadata. Inspect only the public homepage, not the saved private path.
        if result == nil, let (data, responseURL) = await fetch(origin, limit: 262_144, allowPrefix: true), let html = String(data: data, encoding: .utf8) {
            for url in SiteIcon.declared(in: html, base: responseURL) {
                if let image = await candidate(url) { result = image; break }
            }
        }
        if let result {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? result.write(to: file, options: .atomic)
            // Keep the persistent cache bounded, including entries from removed links.
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 256 {
                let oldest = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for url in oldest.prefix(files.count - 256) { try? FileManager.default.removeItem(at: url) }
            }
        }
        return result
    }

    private func fetch(_ url: URL, limit: Int, allowPrefix: Bool = false) async -> (Data, URL)? {
        do {
            var request = URLRequest(url: url)
            request.setValue("image/*,text/html;q=0.5", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  (allowPrefix || response.expectedContentLength <= limit), let final = response.url,
                  Library.validatedURL(final.absoluteString) != nil else { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= limit { return allowPrefix ? (data, final) : nil }
                data.append(byte)
            }
            return (data, final)
        } catch { return nil }
    }
}
