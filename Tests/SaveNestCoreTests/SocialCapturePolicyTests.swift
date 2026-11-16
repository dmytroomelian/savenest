import Foundation
import SaveNestCore

func runSocialCapturePolicyChecks() throws {
    let capture = SocialSaveCapture(platform: "x", url: "https://x.com/example/status/123456789",
        title: "X post", note: "Visible text must be opt-in", observedAt: "2026-11-16T13:13:11Z",
        eventId: "social-policy-fixture", evidence: "accessibility-state-change")
    let linkOnly = try SocialCapturePolicy.inserting(capture, into: Library(), includeText: false)
    precondition(linkOnly.links.count == 1 && linkOnly.links[0].note.isEmpty)
    precondition(linkOnly.links[0].title == "Saved from X" && linkOnly.links[0].collection == "Inbox")
    let withText = try SocialCapturePolicy.inserting(capture, into: Library(), includeText: true)
    precondition(withText.links[0].note == capture.note)
    let slack = SocialSaveCapture(platform: "slack", url: "https://fixture.slack.com/archives/C123/p1234567890123456",
        title: "Private message body", note: "Private message body", observedAt: capture.observedAt,
        eventId: "private-slack-fixture", evidence: capture.evidence)
    let privateLink = try SocialCapturePolicy.inserting(slack, into: Library(), includeText: false).links[0]
    precondition(privateLink.title == "Saved from Slack" && privateLink.note.isEmpty)
    var annotated = withText
    annotated.links[0].note = "My own note"
    annotated.links[0].tags = ["keep"]
    annotated.links[0].isArchived = true
    annotated.links[0].isFavorite = true
    annotated.links[0].title = "My own title"
    let repeated = try SocialCapturePolicy.inserting(capture, into: annotated, includeText: true)
    precondition(repeated == annotated, "A repeated save must preserve every existing annotation and state")
    let invalid = SocialSaveCapture(platform: "x", url: "https://attacker.example/status/123456789",
        title: "Invalid host", note: "", observedAt: capture.observedAt, eventId: "invalid-fixture", evidence: capture.evidence)
    do { _ = try SocialCapturePolicy.inserting(invalid, into: annotated, includeText: false); preconditionFailure("Reject invalid source host") }
    catch { /* Expected: no mutation. */ }
    func mayObserve(_ enabled: Bool = true, _ paused: Bool = false, _ pro: Bool = true,
                    _ preview: Bool = false, _ permission: Bool = true, _ writable: Bool = true, _ account: Bool = true) -> Bool {
        SocialCapturePolicy.mayObserve(enabled: enabled, paused: paused, verifiedPro: pro, preview: preview,
                                       permission: permission, writableLibrary: writable, sameAccount: account)
    }
    precondition(mayObserve())
    precondition(!mayObserve(false) && !mayObserve(true, true) && !mayObserve(true, false, false))
    precondition(!mayObserve(true, false, true, true) && !mayObserve(true, false, true, false, false))
    precondition(!mayObserve(true, false, true, false, true, false) && !mayObserve(true, false, true, false, true, true, false))
    print("Social capture policy checks passed")
}
