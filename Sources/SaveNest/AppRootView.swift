import SwiftUI
import SaveNestCore

/// The secondary window contains preferences and billing only.
struct AppRootView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.black.rawValue
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Settings") { model.section = .settings }
                    .buttonStyle(QuietButton())
                Button("Account & Cloud") { model.section = .account }
                    .buttonStyle(QuietButton())
                Spacer()
                Button("Open SaveNest") { model.showLibrary?() }.buttonStyle(SageButton())
            }.padding(.horizontal, 26).padding(.top, 28).padding(.bottom, 12)
            if model.section == .account {
                AccountView(account: model.account, cloud: model.cloud) { model.showLibrary?() }
            } else {
                SettingsView(model: model) { model.showLibrary?() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper).foregroundStyle(Color.ink).tint(Color.sage).nestAppearance()
        .onChange(of: appearance) { _, value in
            NSApp.appearance = (AppAppearance(rawValue: value) ?? .black).nativeAppearance
        }
    }
}

struct TagsView: View {
    @ObservedObject var model: AppModel
    var onBack: () -> Void = {}
    @AppStorage("tagSummarySortOrder") private var sortOrder = TagSummarySortOrder.alphabetical
    @State private var editingTag: String?
    @State private var draft = ""
    @State private var deletingTag: TagSummary?

    private var sortedTags: [TagSummary] {
        TagSummary.sorted(model.allTagSummaries, by: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBack() } label: { Label("Done", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                Spacer()
                Text("TAGS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(Color.muted)
                Spacer()
                Text("\(model.allTagSummaries.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
            }
            .padding(.horizontal, 34).padding(.top, 25).padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 8) {
                Text("Keep your library easy to browse.").font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                Text("Rename or remove tags everywhere they appear. Select a tag to see matching links.")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
                HStack(spacing: 8) {
                    Spacer()
                    Text("SORT BY").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Color.muted)
                    sortPicker
                }.frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 34).padding(.bottom, 14)

            if model.allTagSummaries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "number").font(.system(size: 20)).foregroundStyle(Color.sage)
                    Text("No tags yet").font(.system(size: 18, weight: .medium))
                    Text("Add tags while saving or editing a link.").font(.system(size: 11)).foregroundStyle(Color.muted)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedTags) { tag in
                            tagRow(tag)
                        }
                    }.padding(.horizontal, 34).padding(.bottom, 30)
                }
            }
            Spacer(minLength: 0)
        }
        .background(Color.paper).foregroundStyle(Color.ink)
        .frame(minWidth: 560, minHeight: 480)
        .alert("Remove #\(deletingTag?.name ?? "")?", isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }), presenting: deletingTag) { tag in
            Button("Cancel", role: .cancel) { deletingTag = nil }
            Button("Remove tag", role: .destructive) { _ = model.deleteTag(tag.name); deletingTag = nil }
        } message: { tag in
            Text("The links will stay in your library. Only this tag will be removed from \(tag.count) \(tag.count == 1 ? "link" : "links").")
        }
    }

    private var sortPicker: some View {
        Menu {
            Button { sortOrder = .alphabetical } label: {
                if sortOrder == .alphabetical { Label("Alphabetical", systemImage: "checkmark") }
                else { Text("Alphabetical") }
            }
            Button { sortOrder = .mostLinks } label: {
                if sortOrder == .mostLinks { Label("Most links", systemImage: "checkmark") }
                else { Text("Most links") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.sage)
                Text(sortOrder == .alphabetical ? "Alphabetical" : "Most links").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.line.opacity(0.65)))
        }.menuStyle(.borderlessButton).fixedSize().help("Sort tags")
    }

    @ViewBuilder private func tagRow(_ tag: TagSummary) -> some View {
        HStack(spacing: 12) {
            if editingTag == tag.name {
                TextField("Tag name", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .onSubmit { saveRename(tag) }
                Button("Save") { saveRename(tag) }.buttonStyle(.link).font(.system(size: 11, weight: .medium))
                Button("Cancel") { editingTag = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.muted)
            } else {
                Button { model.selectTag(tag.name); onBack() } label: {
                    HStack(spacing: 8) {
                        Text("#\(tag.name)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.sage)
                        Text("\(tag.count) \(tag.count == 1 ? "link" : "links")").font(.system(size: 11)).foregroundStyle(Color.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { editingTag = tag.name; draft = tag.name } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(Color.muted).help("Rename \(tag.name)")
                Button { deletingTag = tag } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Color.muted).help("Remove \(tag.name)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .nestSurface()
    }

    private func saveRename(_ tag: TagSummary) {
        let clean = SavedLink.normalizedTags([draft]).first
        guard let clean, clean.caseInsensitiveCompare(tag.name) != .orderedSame else { editingTag = nil; return }
        if model.renameTag(tag.name, to: clean) { editingTag = nil }
    }
}
