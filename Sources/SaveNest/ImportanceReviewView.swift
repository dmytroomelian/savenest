import SwiftUI
import SaveNestCore

struct ImportanceReviewView: View {
    @ObservedObject var model: AppModel
    @State private var showReviewed = false
    @State private var editing: SavedLink?
    private var links: [SavedLink] {
        model.library.links.filter { !$0.isArchived && (showReviewed || $0.importance == nil) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading("What’s worth keeping?", subtitle: "Your choices teach Savenest what matters to you, on this Mac.")
            Text("Mark useful references Important. Add a note with the command, idea, or reason you want to find later. Not needed is a label; archiving is always your choice.")
                .font(.system(size: 12)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("Show reviewed links", isOn: $showReviewed).font(.system(size: 12))
            if !model.learningEnabled {
                Text("Suggestions are off in Settings. You can still review links yourself.").font(.system(size: 11)).foregroundStyle(Color.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if links.isEmpty {
                        Text(showReviewed ? "No active links to review." : "You’re all caught up. Turn on Show reviewed links to change a choice.")
                            .font(.system(size: 13)).foregroundStyle(Color.muted).padding(.vertical, 35)
                    }
                    ForEach(links) { link in
                        reviewRow(link)
                    }
                }
            }
            if let undo = model.archiveUndo {
                HStack { Text(undo.message); Button("Undo") { model.undoArchive() } }.font(.system(size: 12))
            }
        }.padding(30).background(Color.paper)
            .frame(minWidth: 560, minHeight: 480)
            .sheet(item: $editing) { link in LinkDetailView(model: model, link: link) }
    }
    private func reviewRow(_ link: SavedLink) -> some View {
        let suggestion = LinkLearning.suggest(link, examples: model.library.links)
        return VStack(alignment: .leading, spacing: 12) {
            Button { model.open(link) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
                    Text(link.domain).font(.system(size: 11)).foregroundStyle(Color.muted)
                }.multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            if model.learningEnabled || link.importance != nil {
                Text(link.importance?.title ?? suggestion.importance.map { "Suggested: \($0.title)" } ?? "Needs your decision")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.sage)
                Text(suggestion.reason).font(.system(size: 11)).foregroundStyle(Color.muted)
            }
            HStack(spacing: 14) {
                Button("Important") { model.labelImportance(link, .important) }
                Button("Not needed") { model.labelImportance(link, .notNeeded) }
                Button("Add note…") { editing = link }
                Spacer()
                if link.importance != nil { Button("Reset") { model.labelImportance(link, nil) } }
                if link.importance == .notNeeded { Button("Archive") { model.archive(link) } }
            }.buttonStyle(.link).font(.system(size: 11))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).nestSurface()
    }
}
