import SwiftUI
import SaveNestCore

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var now = Date()
    @State private var bulkAction: BulkAction?
    private struct BulkAction: Identifiable {
        let id = UUID()
        let ids: Set<UUID>
        var count: String { "\(ids.count) " + (ids.count == 1 ? "link" : "links") }
    }
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var groups: [LinkDay] {
        guard !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return LinkDay.group(model.visibleLinks, now: now) }
        let ranked = model.visibleLinks.sorted { a, b in
            let aScore = LinkSearch.score(query: model.query, title: a.title, url: a.url, note: a.note, tags: a.tags) ?? 0
            let bScore = LinkSearch.score(query: model.query, title: b.title, url: b.url, note: b.note, tags: b.tags) ?? 0
            return aScore == bScore ? a.createdAt > b.createdAt : aScore > bScore
        }
        return [LinkDay(id: .distantPast, label: "Best matches", links: ranked)]
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !model.onboardingCompleted { onboardingBanner }
            if model.analyticsEnabled && !model.hasSeenUsageNotice && !model.isPreview {
                HStack(alignment: .top, spacing: 10) {
                    Text("Anonymous usage counts are on. No saved content, account IDs, or device IDs are sent.")
                        .font(.system(size: 11)).foregroundStyle(Color.muted)
                    Link("Privacy policy", destination: URL(string: "https://savenest.app/privacy")!).buttonStyle(.link)
                    Button("Turn off") { model.dismissUsageNotice(disable: true) }.buttonStyle(.link)
                    Button { model.dismissUsageNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss usage notice")
                }.padding(14).background(Color.sage.opacity(0.08)).padding(.horizontal, 26).padding(.top, 10)
            }
            filters
            if model.filter == "Archive" && (model.query.isEmpty || !model.searchEverywhere) && !model.archivedIDs.isEmpty {
                HStack {
                    Text("Kept here until you’re ready to let go.").foregroundStyle(Color.muted)
                    Spacer()
                    Button("Empty archive…") { bulkAction = BulkAction(ids: model.archivedIDs) }
                        .buttonStyle(.plain).foregroundStyle(Color.muted).help("Permanently delete all archived links")
                }.font(.system(size: 11)).padding(.horizontal, 38).padding(.top, 14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.query.isEmpty || model.hasRefinements {
                        HStack(spacing: 8) {
                            Text(model.query.isEmpty ? "Filtered library" : "\(model.searchScopeTitle) · “\(model.query)”")
                                .font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1)
                            if let tag = model.selectedTag { resultChip("#\(tag)", icon: "number") }
                            if let domain = model.selectedDomain { resultChip(domain, icon: "globe") }
                            if model.notesOnly { resultChip("Has note", icon: "text.quote") }
                            Spacer()
                            Button("Clear filters") { model.clearFilters() }.buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    if model.visibleLinks.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(groups) { day in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Text(day.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                                        Text("\(day.links.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
                                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.surface, in: Capsule())
                                        Spacer()
                                    }.padding(.horizontal, 3)
                                    VStack(spacing: 0) {
                                        ForEach(Array(day.links.enumerated()), id: \.element.id) { index, link in
                                            SwipeableLink(link: link, model: model) { LinkRow(link: link, model: model) }
                                            if index < day.links.count - 1 { Rectangle().fill(Color.line.opacity(0.45)).frame(height: 1).padding(.leading, 64).padding(.trailing, 16) }
                                        }
                                    }.background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line.opacity(0.6)))
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 26)
            }
            footer
        }
        .background(Color.paper).foregroundStyle(Color.ink)
        .frame(minWidth: 560, minHeight: 480)
        .sheet(item: $model.sharingLink) { EmailShareView(link: $0) }
        .alert(bulkAction.map { "Permanently delete \($0.count)?" } ?? "", isPresented: Binding(get: { bulkAction != nil }, set: { if !$0 { bulkAction = nil } }), presenting: bulkAction) { action in
            Button("Cancel", role: .cancel) { bulkAction = nil }
            Button("Delete forever", role: .destructive) {
                model.emptyArchive(ids: action.ids)
                bulkAction = nil
            }
        } message: { _ in
            Text("These archived links, notes, and tags will be removed from this Mac. This cannot be undone. Links outside Archive are kept.")
        }
        .sheet(isPresented: $model.showingAdd) { AddLinkView(model: model) }
        .sheet(item: Binding(get: { model.selected }, set: { model.selectedID = $0?.id })) { link in LinkDetailView(model: model, link: link) }
        .sheet(isPresented: $model.showingOnboarding) { OnboardingView(model: model) }
        .alert("Couldn’t finish that", isPresented: Binding(get: { model.error != nil && !model.showingAdd && model.selectedID == nil && model.sharingLink == nil && bulkAction == nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
            if model.error?.contains("Automation") == true {
                Button("Automation Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
            }
        } message: { Text(model.error ?? "") }
        .onExitCommand { model.swipedLinkID = nil }
        .onChange(of: model.selectedTag) { _, _ in model.swipedLinkID = nil }
        .onChange(of: model.selectedDomain) { _, _ in model.swipedLinkID = nil }
        .onChange(of: model.notesOnly) { _, _ in model.swipedLinkID = nil }
        .onChange(of: model.query) { oldValue, newValue in
            if oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.searchEverywhere = true
            }
        }
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
    }
    private var filters: some View {
        HStack(spacing: 4) {
            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { model.searchEverywhere = true } label: { filterLabel("Everywhere", selected: model.searchEverywhere) }
                    .buttonStyle(.plain).help("Search active and archived links")
            }
            scope("Library", filter: "All links")
            scope("Favorites", filter: "Favorites")
            Button { model.notesOnly.toggle() } label: {
                filterLabel("Notes", selected: model.notesOnly)
            }.buttonStyle(.plain).help("Show links with notes")
            scope("Archive", filter: "Archive")
            Spacer()
            Menu {
                Menu("Tags") {
                    Button("All tags") { model.selectedTag = nil }
                    Divider()
                    ForEach(model.tagSummaries) { tag in
                        Button("\(tag.name)  ·  \(tag.count)") { model.selectedTag = tag.name }
                    }
                }
                Menu("Websites") {
                    Button("All websites") { model.selectedDomain = nil }
                    Divider()
                    ForEach(model.domainOptions, id: \.self) { domain in
                        Button(domain) { model.selectedDomain = domain }
                    }
                }
                Toggle("Has a note", isOn: $model.notesOnly)
                if model.hasRefinements {
                    Divider()
                    Button("Clear refinements") { model.selectedTag = nil; model.selectedDomain = nil; model.notesOnly = false }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(Color.muted)
                .help("Filter results").accessibilityLabel("Filter results")
        }.padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 2)
    }
    private var onboardingBanner: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.sage)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setting up Savenest").font(.system(size: 11, weight: .medium))
                Text("Take the 45-second tour to learn the shortcuts and gestures.").font(.system(size: 10)).foregroundStyle(Color.muted)
            }
            Spacer()
            Button("Continue") { model.showOnboarding() }.buttonStyle(QuietButton())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.sage.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sage.opacity(0.2)))
        .padding(.horizontal, 26).padding(.top, 15)
    }
    private func scope(_ title: String, filter: String) -> some View {
        Button {
            model.filter = filter
            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.searchEverywhere = false }
            model.notesOnly = false; model.selectedTag = nil; model.selectedDomain = nil
        } label: {
            filterLabel(title, selected: model.filter == filter && !model.notesOnly && (model.query.isEmpty || !model.searchEverywhere))
        }.buttonStyle(.plain)
    }
    private func resultChip(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.sage)
            .padding(.horizontal, 8).padding(.vertical, 4).background(Color.sage.opacity(0.10), in: Capsule())
    }
    private func filterLabel(_ title: String, selected: Bool) -> some View {
        Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.sage : Color.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? Color.sage.opacity(0.12) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.sage.opacity(0.28) : .clear))
    }
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                HStack(spacing: 7) { NestMark().frame(width: 22, height: 22); Text("savenest").font(.system(size: 15, weight: .semibold)).tracking(-0.4) }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.isCapturing ? Color.orange : Color.sage).frame(width: 5, height: 5)
                    Text(model.isPreview ? "Sample library" : model.isCapturing ? "Saving…" : "On your Mac").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted)
                }
            }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(model.isTagSearch ? Color.sage : Color.muted)
                    TextField("Search every link", text: $model.query).textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(model.isTagSearch ? Color.sage : Color.ink).focused($searchFocused)
                        .help("Search titles, full web addresses, notes, tags, and archived links. Type # to find a tag.")
                    if !model.query.isEmpty {
                        Menu {
                            Button { model.searchEverywhere = true } label: {
                                if model.searchEverywhere { Label("Everywhere", systemImage: "checkmark") } else { Text("Everywhere") }
                            }
                            Button {
                                model.searchEverywhere = false
                            } label: {
                                if !model.searchEverywhere { Label(model.filter == "All links" ? "Library" : model.filter, systemImage: "checkmark") }
                                else { Text(model.filter == "All links" ? "Library" : model.filter) }
                            }
                        } label: {
                            Text(model.searchScopeTitle).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.sage)
                        }.menuStyle(.borderlessButton).fixedSize().help("Choose where to search")
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Color.muted).help("Clear search")
                    } else { Text("⌘F").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted.opacity(0.55)) }
                }.padding(.horizontal, 14).padding(.vertical, 13).background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(searchFocused ? Color.sage.opacity(0.5) : Color.line.opacity(0.65)))
                if searchFocused && model.isTagSearch && !model.tagSearchSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("TAGS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(Color.muted).padding(.horizontal, 13).padding(.top, 10).padding(.bottom, 6)
                        ForEach(model.tagSearchSuggestions) { tag in
                            Button { model.selectTag(tag.name); searchFocused = false } label: {
                                HStack {
                                    Text("#\(tag.name)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.sage)
                                    Spacer()
                                    Text("\(tag.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted)
                                }.padding(.horizontal, 13).padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.frame(width: 250, alignment: .leading).nestSurface(elevated: true).shadow(color: .black.opacity(0.35), radius: 16, y: 8).offset(y: 50)
                }
            }
        }.padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 0).zIndex(1)
    }
    private var emptyState: some View {
        VStack(spacing: 0) {
            NestMark().frame(width: 52, height: 52).padding(22).background(Color.sage.opacity(0.055), in: RoundedRectangle(cornerRadius: 25)).padding(.bottom, 24)
            Text(model.query.isEmpty && !model.hasRefinements ? (model.filter == "Archive" ? "Nothing archived." : "A little room for good things.") : "No matching links.")
                .font(.system(size: 22, weight: .semibold)).padding(.bottom, 12)
            Text(model.query.isEmpty && !model.hasRefinements ? (model.filter == "Archive" ? "Swipe left on a saved link to move it here." : "Open a browser tab and press") : "Try fewer words, another tag, or clear your filters.")
                .font(.system(size: 12)).foregroundStyle(Color.muted)
            if model.query.isEmpty && !model.hasRefinements && model.filter != "Archive" {
                Text(model.shortcut.label).font(.system(size: 17, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 17).padding(.vertical, 10).nestSurface(radius: 10).padding(.top, 15)
                Text("Saved instantly. Right here when you need it.").font(.system(size: 11)).foregroundStyle(Color.muted).padding(.top, 18)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 44)
    }
    private var footer: some View {
        HStack(spacing: 7) {
            if let undo = model.archiveUndo {
                Image(systemName: "archivebox").foregroundStyle(Color.sage)
                Text(undo.message)
                Button("Undo") { model.undoArchive() }.buttonStyle(.link)
                Button { model.dismissArchiveUndo() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss undo").accessibilityLabel("Dismiss undo")
            } else if let notice = model.toast {
                Image(systemName: notice.isError ? "exclamationmark.circle" : "checkmark.circle.fill").foregroundStyle(notice.isError ? Color.orange : Color.sage)
                Text(notice.title)
            } else if model.isCapturing {
                ProgressView().controlSize(.mini)
                Text("Saving…")
            } else {
                Button { model.showSettings?() } label: {
                    HStack(spacing: 8) {
                        Text(model.shortcut.label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.sage)
                        Text(model.closeAfterQuickSave ? "to save & close a tab" : "to save a tab")
                    }
                }.buttonStyle(.plain).help("Change capture shortcut")
            }
            Spacer()
            Image(systemName: "lock").font(.system(size: 9))
            Text("Only on your Mac")
        }.font(.system(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 26).padding(.vertical, 15)
            .background(Color.sidebar.opacity(0.4))
            .overlay(alignment: .top) { Rectangle().fill(Color.line.opacity(0.5)).frame(height: 1) }

    }
}

struct LinkRow: View {
    let link: SavedLink
    @ObservedObject var model: AppModel
    @State private var hovered = false
    private var hasNote: Bool { !link.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DomainIcon(domain: link.domain, url: link.url, iconURL: link.iconURL).scaleEffect(0.86).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 8) {
                Button { model.open(link) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(link.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 7) {
                            Text(link.domain).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(1)
                            if link.isArchived {
                                Text("Archived").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.muted)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.raised, in: Capsule())
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open in browser")
                if hasNote {
                    Button { model.selectedID = link.id } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "text.quote").font(.system(size: 10)).padding(.top, 2)
                            Text(link.note).font(.system(size: 12)).lineSpacing(3).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.foregroundStyle(Color.muted).padding(10)
                            .background(Color.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).help("Edit note")
                }
                if !link.tags.isEmpty {
                    TagFlowLayout(spacing: 5) {
                        ForEach(link.tags, id: \.self) { tag in
                            Button { model.selectedTag = tag } label: { Text("#" + tag).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4).background(Color.sage.opacity(0.10), in: Capsule()) }.buttonStyle(.plain).foregroundStyle(Color.sage).help("Find links tagged \(tag)")
                        }
                    }
                }

            }
            HStack(spacing: 12) {
                Button { model.selectedID = link.id } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("Edit note and tags").accessibilityLabel("Edit note and tags")
                Button { model.favorite(link) } label: { Image(systemName: link.isFavorite ? "star.fill" : "star").foregroundStyle(link.isFavorite ? Color.sage : Color.muted.opacity(0.5)) }.buttonStyle(.plain).help(link.isFavorite ? "Remove favorite" : "Favorite link").accessibilityLabel(link.isFavorite ? "Remove favorite" : "Favorite link")
                Menu {
                    Button("Open in browser") { model.open(link) }
                    Button("Copy link") { model.copy(link) }
                    Button("Share by email…") { model.share(link) }
                    Button("Edit title, note & tags…") { model.selectedID = link.id }
                    Divider()
                    Button("Mark Important") { model.labelImportance(link, .important) }
                    Button("Mark Not needed") { model.labelImportance(link, .notNeeded) }
                    if link.importance != nil { Button("Reset importance") { model.labelImportance(link, nil) } }
                    Divider()
                    if !link.isArchived { Button("Delete", role: .destructive) { model.delete(link) } }
                    Button(link.isArchived ? "Restore to library" : "Archive") { model.archive(link) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).help("Link options")
            }.font(.system(size: 12)).foregroundStyle(Color.muted).opacity(hovered ? 1 : 0.65).padding(.top, 3)
        }.padding(14).background(hovered ? Color.raised.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .onHover { hovered = $0 }
            .contextMenu {
                Button("Open in browser") { model.open(link) }
                Button("Copy link") { model.copy(link) }
                Button("Share by email…") { model.share(link) }
                Button("Edit note & tags…") { model.selectedID = link.id }
                if !link.isArchived { Button("Delete", role: .destructive) { model.delete(link) } }
                Button(link.isArchived ? "Restore to library" : "Archive") { model.archive(link) }
            }
    }
}

extension Notification.Name { static let focusSearch = Notification.Name("SaveNest.focusSearch") }
