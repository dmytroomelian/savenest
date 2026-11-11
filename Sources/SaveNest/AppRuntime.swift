import Foundation

/// Private beta builds use their own data and credential namespace. No user
/// setting or imported library can change the backend receiving a session.
enum AppRuntime {
    static let betaBundleID = "app.savenest.aws-beta"
    static var isPrivateBeta: Bool { Bundle.main.bundleIdentifier == betaBundleID }
    static var supportFolderName: String { isPrivateBeta ? "SaveNest AWS Beta" : "SaveNest" }
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportFolderName, isDirectory: true)
    }
    static var keychainService: String { isPrivateBeta ? "app.savenest.aws-beta.account" : "app.savenest.mac.account" }
    static var accountOrigin: URL {
        accountOrigin(bundleID: Bundle.main.bundleIdentifier,
                      configured: Bundle.main.object(forInfoDictionaryKey: "SaveNestAccountBaseURL") as? String)
    }
    static func accountOrigin(bundleID: String?, configured: String?) -> URL {
        // The beta is intentionally pinned to this AWS deployment. Production
        // bundles keep their original origin and credential namespace.
        if bundleID == betaBundleID {
            precondition(configured == "https://d7ltannvnl.execute-api.eu-north-1.amazonaws.com", "Invalid private beta backend configuration")
            return URL(string: configured!)!
        }
        return URL(string: "https://savenest.app")!
    }
    static func canonicalCallback(_ url: URL, beta: Bool = isPrivateBeta) -> URL? {
        guard url.scheme == (beta ? "savenest-beta" : "savenest"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Core validates host, path, state and one-use PKCE code as usual.
        components.scheme = "savenest"
        return components.url
    }
}
