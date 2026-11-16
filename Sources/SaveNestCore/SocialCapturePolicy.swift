import Foundation

public enum SocialCapturePolicy {
    /// Inserting an observed save must never silently edit an existing record.
    public static func inserting(_ value: SocialSaveCapture, into library: Library, includeText: Bool) throws -> Library {
        let capture = try value.validated()
        guard !library.links.contains(where: { Library.identity($0.url) == Library.identity(capture.url) }) else { return library }
        let platform = ["slack": "Slack", "linkedin": "LinkedIn", "x": "X"][capture.platform] ?? "Social"
        var title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slack's accessible title can be the message body itself.
        if !includeText && capture.platform == "slack" { title = "Saved from Slack" }
        if title.isEmpty || title == "X post" { title = "Saved from \(platform)" }
        var link = SavedLink(url: capture.url, title: String(title.prefix(500)), browser: platform)
        if includeText { link.note = String(capture.note.prefix(20_000)) }
        var result = library
        _ = result.insert([link])
        return result
    }
    public static func mayObserve(enabled: Bool, paused: Bool, verifiedPro: Bool, preview: Bool,
                                  permission: Bool, writableLibrary: Bool, sameAccount: Bool) -> Bool {
        enabled && !paused && verifiedPro && !preview && permission && writableLibrary && sameAccount
    }
}
