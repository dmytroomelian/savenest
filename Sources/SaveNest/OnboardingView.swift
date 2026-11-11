import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                NestMark().frame(width: 30, height: 30)
                Text("Welcome to Savenest").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("All your tabs. One place.").font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                Text("Free on your Mac. No account required. Search open tabs and saved links, switch to a page, or keep it for later.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted).lineSpacing(3)
            }
            VStack(spacing: 0) {
                shortcutRow("Open Savenest", subtitle: "Search from anywhere on your Mac", icon: "magnifyingglass", action: .search)
                Divider().padding(.leading, 48)
                shortcutRow("Save current tab", subtitle: "Keep the page and carry on browsing", icon: "bookmark", action: .quick)
                Divider().padding(.leading, 48)
                shortcutRow("Save with a note", subtitle: "Remember why it mattered", icon: "square.and.pencil", action: .note)
            }.padding(14).nestSurface()
            HStack(alignment: .top, spacing: 12) {
                Text("⌘K").font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(Color.sage)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Every action, right here.").font(.system(size: 13, weight: .medium))
                    Text("Save, close, add notes and tags, archive, or copy. Use ↑ ↓ and Return to choose. Select several rows to act on them together.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted).lineSpacing(3)
                }
            }
            Text("macOS may ask for browser access. Page context becomes searchable when your browser allows JavaScript from Apple Events. Your links and page text stay on this Mac.")
                .font(.system(size: 11)).foregroundStyle(Color.muted).lineSpacing(3)
            HStack {
                Text("Shortcuts stay visible in the main window.").font(.system(size: 10)).foregroundStyle(Color.muted)
                Spacer()
                Button("Show my tabs") { model.completeOnboarding(); dismiss() }
                    .buttonStyle(SageButton()).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540).background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
            .onExitCommand { model.completeOnboarding(); dismiss() }
    }
    private func shortcutRow(_ title: String, subtitle: String, icon: String, action: CaptureAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.sage).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.muted)
            }
            Spacer()
            Text((model.shortcuts[action] ?? action.defaultShortcut).label)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 8).background(Color.raised, in: RoundedRectangle(cornerRadius: 8))
        }.padding(.vertical, 12)
    }
}
