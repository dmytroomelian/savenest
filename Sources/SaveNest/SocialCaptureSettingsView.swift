import SwiftUI

struct SocialCaptureSettingsView: View {
    @ObservedObject var controller: SocialCaptureController
    @ObservedObject var account: AccountController
    var openAccount: () -> Void
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Save from other apps", systemImage: "bookmark.square").font(.system(size: 16, weight: .semibold))
                Text("PRO · BETA").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.sage)
                Spacer()
                Button("How it works") { showingDetails = true }.buttonStyle(.link)
            }
            Text("Save in Slack, LinkedIn or X. Find it again in Savenest.")
                .font(.system(size: 12)).foregroundStyle(Color.muted)
            Toggle("Save from other apps", isOn: Binding(get: { controller.preferences.enabled }, set: { value in
                Task { await controller.setEnabled(value) }
            })).disabled(!controller.available || controller.changing)
            Text(controller.status).font(.system(size: 11)).foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true).accessibilityLabel("Capture status: " + controller.status)
            if !controller.hasAccess {
                HStack {
                    Button("Account & Pro…", action: openAccount).buttonStyle(QuietButton())
                    if account.hasLogin { Button("Refresh access") { Task { await controller.refreshAccess() } }.buttonStyle(.link) }
                }
            }
            if !controller.permissionGranted && controller.available {
                Button("Enable Accessibility…") { controller.requestPermission() }.buttonStyle(QuietButton())
            }
            VStack(alignment: .leading, spacing: 11) {
                source("slack", "Slack for Mac")
                source("linkedin", "LinkedIn in Safari or Chrome")
                if controller.preferences.platforms.contains("linkedin") {
                    Toggle("Allow LinkedIn’s automatic Copy link step", isOn: Binding(get: { controller.preferences.allowLinkedInCopy }, set: controller.setLinkedInCopy))
                        .font(.system(size: 11)).padding(.leading, 20)
                    Text("Briefly reopens the saved post’s menu, copies its link, then restores your clipboard. Leave the browser untouched for a few seconds.")
                        .font(.system(size: 11)).foregroundStyle(Color.muted).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
                }
                source("x", "X in Safari or Chrome")
            }.disabled(!controller.available)
            Divider()
            Toggle("Include visible post or message text as a note", isOn: Binding(get: { controller.preferences.includeText }, set: controller.setIncludeText))
                .disabled(!controller.available)
            Text("Links, titles and optional notes follow your library’s cloud saving and AI connection permissions.")
                .font(.system(size: 11)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            if controller.preferences.enabled {
                Button(controller.preferences.paused ? "Resume capture" : "Pause capture") {
                    controller.setPaused(!controller.preferences.paused)
                }.buttonStyle(QuietButton())
            }
        }.padding(20).nestSurface()
            .sheet(isPresented: $showingDetails) { information }
    }
    private func source(_ id: String, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { controller.preferences.platforms.contains(id) }, set: { controller.setPlatform(id, enabled: $0) }))
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your usual Save button. One library.").font(.system(size: 22, weight: .semibold))
            Text("Turn on capture, choose your apps, and grant Savenest Accessibility access. Use Slack’s Save for later or a post’s Save / Bookmark button as usual.")
            Text("Savenest reads the enabled app’s accessible controls while it is in front. No browser extension, social account connection, or imported bookmark history is required. Saves from other devices are not imported.")
            Text("Slack needs to see a message before and after it becomes saved. LinkedIn briefly reopens the same post’s menu to copy its link and restores the clipboard. X exposes the post link directly. Clicking, typing, scrolling or switching apps during LinkedIn’s copy can cancel it; newer clipboard content is preserved.")
            Text("Captured links enter your normal Savenest library. Pro cloud saving and any permitted AI connections apply to them too. Visible text is included only if you enable that option. Existing saved notes and tags are preserved.")
            Text("Beta: tested with Slack for Mac and Safari. Chrome support is experimental. Site changes, fast scrolling and incomplete views can cause missed saves. Pro access is checked online; capture pauses if access cannot be verified. Manual local saving stays available.")
            HStack { Spacer(); Button("Got it") { showingDetails = false }.buttonStyle(SageButton()) }
        }.font(.system(size: 12)).foregroundStyle(Color.ink).padding(28).frame(width: 540)
            .background(Color.paper).nestAppearance()
    }
}
