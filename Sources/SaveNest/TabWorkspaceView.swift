import AppKit
import SwiftUI
import SaveNestCore

struct TabSearchView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: TabSearchModel
    @FocusState private var searchFocused: Bool
    @State private var showingActions = false
    @State private var showingTags = false
    @State private var editingLink: SavedLink?
    @State private var pendingAction: PendingAction?
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.black.rawValue

    private struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let perform: () -> Void
    }
    private var selectedTabs: [OpenBrowserTab] { model.selectedItems.compactMap(\.tab) }
    private var selectedLinks: [SavedLink] {
        var seen = Set<UUID>()
        return model.selectedItems.compactMap(\.link).filter { seen.insert($0.id).inserted }
    }
    private var isPresenting: Bool { app.showingAdd || editingLink != nil || showingTags || app.showingOnboarding || app.sharingLink != nil || app.cleanupReview != nil || pendingAction != nil }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            scopeBar
            if !app.onboardingCompleted { welcomeBar }
            if app.analyticsEnabled && !app.hasSeenUsageNotice && !app.isPreview { usageNotice }
            shortcutsBar
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
            }
            resultsList
            footer
        }
        .frame(width: 720, height: 650)
        .background(Color.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.line.opacity(0.8)))
        .overlay(alignment: .bottomTrailing) {
            if showingActions {
                WorkspaceActionMenu(commands: commands, dismiss: { showingActions = false })
                    .padding(12).padding(.bottom, 40)
            }
        }
        .foregroundStyle(Color.ink).tint(Color.sage).nestAppearance()
        .onAppear { searchFocused = true; app.workspaceKeyHandler = handleKey }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in showingActions = false; searchFocused = true }
        .onChange(of: app.library) { _, library in model.updateLibrary(library.links) }
        .onChange(of: showingActions) { _, shown in searchFocused = !shown }
        .onChange(of: isPresenting) { _, shown in if !shown { searchFocused = true } }
        .onChange(of: appearance) { _, value in NSApp.appearance = (AppAppearance(rawValue: value) ?? .black).nativeAppearance }
        .sheet(item: $editingLink) { link in WorkspaceLinkEditor(app: app, link: link) }
        .sheet(isPresented: $app.showingAdd) { AddLinkView(model: app) }
        .sheet(isPresented: $app.showingOnboarding) { OnboardingView(model: app) }
        .sheet(isPresented: $showingTags) { TagsView(model: app, onBack: { showingTags = false }) }
        .sheet(item: $app.sharingLink) { EmailShareView(link: $0) }
        .sheet(item: $app.cleanupReview) { TabCleanupReviewView(model: app, draftID: $0.id) }
        .alert(pendingAction?.title ?? "", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), presenting: pendingAction) { action in
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button("Confirm", role: .destructive) { action.perform(); pendingAction = nil }
        } message: { Text($0.detail) }
        .alert("Couldn’t finish that", isPresented: Binding(get: { app.error != nil && !isPresenting }, set: { if !$0 { app.error = nil } })) {
            Button("OK", role: .cancel) { app.error = nil }
        } message: { Text(app.error ?? "") }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(Color.sage)
            TextField("Search tabs, saved links, or page context…", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 19)).focused($searchFocused)
                .onSubmit { if !showingActions, let item = model.selected { open(item) } }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
            if model.loading || model.busy || model.switching { ProgressView().controlSize(.small) }
            Button { escape() } label: { Text("esc").font(.system(size: 10, design: .monospaced)) }
                .buttonStyle(QuietButton()).help("Close Savenest")
        }.padding(20)
    }
    private var scopeBar: some View {
        HStack(spacing: 5) {
            ForEach(Array(TabScope.allCases.enumerated()), id: \.element.id) { offset, scope in
                Button { model.scope = scope; searchFocused = true } label: {
                    Text(scope.rawValue).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.scope == scope ? Color.ink : Color.muted)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(model.scope == scope ? Color.sage.opacity(0.17) : .clear, in: Capsule())
                }.buttonStyle(.plain).keyboardShortcut(KeyEquivalent(Character(String(offset + 1))), modifiers: .option)
                    .help("\(scope.rawValue) · ⌥\(offset + 1)").accessibilityAddTraits(model.scope == scope ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button { showingActions.toggle() } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                .buttonStyle(.plain).help("All actions · ⌘K").accessibilityLabel("All actions")
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }
    private var shortcutsBar: some View {
        HStack(spacing: 14) {
            shortcutHint("Open Savenest", action: .search)
            shortcutHint("Save tab", action: .quick)
            shortcutHint("Add note", action: .note)
            Spacer(minLength: 0)
            Button { app.showingOnboarding = true } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain).help("Quick start").accessibilityLabel("Quick start")
        }.font(.system(size: 10)).foregroundStyle(Color.muted)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(Color.surface.opacity(0.65)).padding(.bottom, 10)
    }
    private func shortcutHint(_ title: String, action: CaptureAction) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text((app.shortcuts[action] ?? action.defaultShortcut).label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.ink)
        }
    }
    private var welcomeBar: some View {
        HStack(spacing: 10) {
            Text("All your tabs. One place.").font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Quick start") { app.showingOnboarding = true }.buttonStyle(.link)
            Button { app.completeOnboarding() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss quick start")
        }.padding(12).background(Color.sage.opacity(0.08)).padding(.horizontal, 18).padding(.bottom, 10)
    }
    private var usageNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Anonymous usage counts are on. No saved content, account IDs, or device IDs are sent.")
            Spacer()
            Link("Privacy policy", destination: URL(string: "https://savenest.app/privacy")!).buttonStyle(.link)
            Button("Turn off") { app.dismissUsageNotice(disable: true) }.buttonStyle(.link)
            Button { app.dismissUsageNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss usage notice")
        }.font(.system(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 20).padding(.bottom, 12)
    }
    private var resultsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.markedIDs.isEmpty ? "\(model.results.count) \(model.results.count == 1 ? "result" : "results")" : "\(model.markedIDs.count) selected")
                if !model.markedIDs.isEmpty { Button("Clear") { model.markedIDs = [] }.buttonStyle(.link) }
                Spacer()
                if model.loadingContext { Text("Adding page context…") }
                if model.contextUnavailable {
                    Button("Page context limited") { showingActions = true }.buttonStyle(.plain)
                        .help("Some browsers block page text. Allow JavaScript from Apple Events in that browser, then choose Retry page context. Title and URL search still work.")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                    .disabled(model.loading).help("Refresh tabs · ⌘R").accessibilityLabel("Refresh tabs")
            }.font(.system(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 22).padding(.bottom, 8)
            if model.results.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 28)).foregroundStyle(Color.sage)
                    Text(model.loading ? "Finding your tabs…" : model.query.isEmpty ? "A little room to start." : "No matches yet.")
                        .font(.system(size: 18, weight: .medium))
                    Text(model.query.isEmpty ? "Open a browser, or save a link to keep it here." : "Try a title, website, phrase from the page, note, or #tag.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                    if model.query.isEmpty { Button("Add a link") { app.presentAdd() }.buttonStyle(QuietButton()) }
                    else { Button("Search everything") { model.scope = .all }.buttonStyle(.link) }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { offset, item in
                                resultRow(item, offset: offset).id(item.id)
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .onChange(of: model.selected?.id) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func resultRow(_ item: TabWorkspaceItem, offset: Int) -> some View {
        HStack(spacing: 0) {
            Button { model.selectedIndex = offset; model.toggleSelection(item) } label: {
                Image(systemName: model.markedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(model.markedIDs.contains(item.id) ? Color.sage : Color.muted.opacity(0.5)).frame(width: 30, height: 64)
            }.buttonStyle(.plain).help("Select for bulk actions").accessibilityLabel("Select \(item.title)")
            Button { model.selectedIndex = offset; open(item) } label: {
                HStack(spacing: 10) {
                    DomainIcon(domain: item.domain, url: item.url, iconURL: item.link?.iconURL).scaleEffect(0.67).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if item.link?.isFavorite == true { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.sage) }
                        }
                        HStack(spacing: 5) {
                            Text(item.domain)
                            if let tab = item.tab { Text("· \(tab.browserName) · Window \(tab.windowID)") }
                            if let link = item.link { Text(link.isArchived ? "· Archived" : "· Saved").foregroundStyle(Color.sage) }
                            if let tag = item.link?.tags.first { Text("· #\(tag)") }
                        }.font(.system(size: 10)).foregroundStyle(Color.muted).lineLimit(1)
                        let detail = snippet(item)
                        if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if offset < 9 { Text("⌘\(offset + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 68).contentShape(Rectangle())
            }.buttonStyle(.plain).workspaceJumpShortcut(offset)
            Button { model.selectedIndex = offset; showingActions = true } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 64)
            }.buttonStyle(.plain).help("Actions for \(item.title)").accessibilityLabel("Actions for \(item.title)")
        }
        .padding(.horizontal, 6)
        .background(model.selectedIndex == offset ? Color.sage.opacity(0.12) : Color.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(model.selectedIndex == offset ? Color.sage.opacity(0.3) : .clear))
        .contextMenu { rowContextMenu(item) }
    }
    @ViewBuilder private func rowContextMenu(_ item: TabWorkspaceItem) -> some View {
        Button(item.tab == nil ? "Open link" : "Switch to tab") { open(item) }
        Button("Copy URL") { copy([item]) }
        Button("Edit title, note & tags…") { edit(item) }
        if let tab = item.tab {
            if item.link == nil { Button("Save tab") { model.saveTabs([tab]) } }
            Button("Save & close tab") { model.saveTabs([tab], closeAfter: true) }
            Button("Close tab") { model.closeTabs([tab]) }
        }
        if let link = item.link {
            Button(link.isFavorite ? "Remove favorite" : "Favorite") { app.favorite(link) }
            Button(link.isArchived ? "Restore saved link" : "Archive saved link") { app.archive(link) }
            Button("Email link…") { app.share(link) }
            Button("Delete saved link…", role: .destructive) { confirmDelete([link]) }
        }
    }
    private func snippet(_ item: TabWorkspaceItem) -> String {
        let note = item.link?.note ?? ""
        let text = item.context.isEmpty ? note : item.context
        let words = model.query.split(whereSeparator: \.isWhitespace).map(String.init)
        if let range = words.lazy.compactMap({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first {
            let start = text.index(range.lowerBound, offsetBy: -35, limitedBy: text.startIndex) ?? text.startIndex
            return (start == text.startIndex ? "" : "…") + String(text[start...].prefix(160))
        }
        return String((note.isEmpty ? text : note).prefix(160)).replacingOccurrences(of: "\n", with: " ")
    }
    private var footer: some View {
        HStack(spacing: 14) {
            NestMark().frame(width: 18, height: 18)
            Text("↑ ↓ select")
            Text(model.selected?.tab == nil ? "↵ open" : "↵ switch")
            if app.canUndoLastAction { Button("Undo") { app.undoLastAction() }.buttonStyle(.link) }
            Spacer()
            Button { app.showSettings?() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings & account").accessibilityLabel("Settings & account")
            Button { showingActions.toggle() } label: {
                HStack(spacing: 8) { Text("Actions"); Text("⌘K").font(.system(size: 10, design: .monospaced)) }
            }.buttonStyle(QuietButton())
        }.font(.system(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color.surface.opacity(0.65))
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !isPresenting else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.isEmpty, event.keyCode == 53 { escape(); return true }
        if flags == .command, key == "k" { showingActions.toggle(); return true }
        guard !showingActions else { return false }
        if flags == .option, let number = Int(key), (1...TabScope.allCases.count).contains(number) {
            model.scope = TabScope.allCases[number - 1]; return true
        }
        if flags == [.shift], event.keyCode == 49 {
            if let item = model.selected { model.toggleSelection(item) }; return true
        }
        if flags == [.command, .shift], key == "c" { copy(model.selectedItems); return true }
        guard flags == .command else { return false }
        if let number = Int(key), (1...9).contains(number), model.results.indices.contains(number - 1) {
            open(model.results[number - 1]); return true
        }
        switch key {
        case "s": model.saveTabs(selectedTabs)
        case "e": if let item = model.selected { edit(item) }
        case "r": model.refresh()
        case "n": app.presentAdd()
        case "f": searchFocused = true
        case ",": app.showSettings?()
        default:
            if event.keyCode == 51 { closeSelected() }
            else { return false }
        }
        return true
    }
    private var commands: [WorkspaceCommand] {
        var list: [WorkspaceCommand] = []
        let items = model.selectedItems, tabs = selectedTabs, links = selectedLinks
        let suffix = items.count > 1 ? " (\(items.count))" : ""
        if let item = model.selected, model.markedIDs.count <= 1 {
            list.append(.init("open", item.tab == nil ? "Open link" : "Switch to tab", "arrow.up.right", "↵") { open(item) })
            list.append(.init("edit", "Edit title, note & tags…", "square.and.pencil", "⌘E") { edit(item) })
        }
        if !items.isEmpty { list.append(.init("copy", "Copy URL" + suffix, "doc.on.doc", "⇧⌘C") { copy(items) }) }
        if !tabs.isEmpty {
            list.append(.init("save", "Save tabs" + suffix, "bookmark", "⌘S", enabled: !model.busy) { model.saveTabs(tabs) })
            list.append(.init("save-close", "Save & close tabs" + suffix, "bookmark.circle", enabled: !model.busy) { model.saveTabs(tabs, closeAfter: true) })
            list.append(.init("close", "Close tabs" + suffix, "xmark.square", "⌘⌫", enabled: !model.busy) { closeSelected() })
        }
        if let link = links.first, links.count == 1 {
            list.append(.init("favorite", link.isFavorite ? "Remove favorite" : "Favorite", "star") { app.favorite(link) })
            list.append(.init("email", "Email link…", "envelope") { app.share(link) })
        }
        if !links.isEmpty {
            let restore = links.allSatisfy(\.isArchived)
            list.append(.init("archive", (restore ? "Restore saved links" : "Archive saved links") + suffix, "archivebox") { app.setArchived(!restore, ids: Set(links.map(\.id))) })
            list.append(.init("delete", "Delete saved links…" + suffix, "trash") { confirmDelete(links) })
        }
        list.append(.init("select-all", "Select all results", "checkmark.square") { model.markedIDs = Set(model.results.map(\.id)) })
        if !model.markedIDs.isEmpty { list.append(.init("deselect", "Clear selection", "square") { model.markedIDs = [] }) }
        list.append(.init("add", "Add a link…", "plus", "⌘N") { app.presentAdd() })
        list.append(.init("clipboard", "Save copied link", "doc.on.clipboard") { app.saveCurrentClipboard() })
        list.append(.init("duplicates", "Close duplicate & empty tabs", "rectangle.on.rectangle.slash", enabled: !app.isCleaningTabs) { app.closeDuplicateTabs() })
        list.append(.init("tags", "Manage tags…", "number") { showingTags = true })
        list.append(.init("refresh", "Refresh open tabs", "arrow.clockwise", "⌘R") { model.refresh() })
        if model.contextUnavailable { list.append(.init("context", "Retry page context", "text.magnifyingglass") { model.retryContext() }) }
        if app.canUndoLastAction { list.append(.init("undo", "Undo last library change", "arrow.uturn.backward", "⌘Z") { app.undoLastAction() }) }
        if model.scope == .archive, !app.archivedIDs.isEmpty {
            let ids = app.archivedIDs
            list.append(.init("empty", "Empty archive…", "trash") {
                pendingAction = PendingAction(title: "Permanently delete \(ids.count) archived links?", detail: "This removes their notes and tags too. This cannot be undone.", perform: { app.emptyArchive(ids: ids) })
            })
        }
        if !app.activeIDs.isEmpty {
            let ids = app.activeIDs
            list.append(.init("archive-all", "Archive all saved links…", "archivebox") {
                pendingAction = PendingAction(title: "Archive \(ids.count) saved links?", detail: "Notes and tags stay with your links. You can undo this change.", perform: { app.setArchived(true, ids: ids) })
            })
        }
        list.append(.init("export", "Export library backup…", "square.and.arrow.up") { app.exportLibrary() })
        list.append(.init("import", "Import library backup…", "square.and.arrow.down") { app.importLibrary() })
        list.append(.init("help", "Quick start & shortcuts", "questionmark.circle") { app.showingOnboarding = true })
        list.append(.init("settings", "Settings…", "gearshape", "⌘,") { app.showSettings?() })
        list.append(.init("account", "Account & Pro…", "person.crop.circle") { app.showAccount?() })
        return list
    }
    private func open(_ item: TabWorkspaceItem) {
        if let tab = item.tab { model.activate(tab) }
        else { app.open(item.link ?? SavedLink(url: item.url, title: item.title, browser: item.history?.browser ?? "History")); model.close?() }
    }
    private func edit(_ item: TabWorkspaceItem) {
        editingLink = item.link ?? SavedLink(url: item.url, title: item.title, browser: item.tab?.browserName ?? item.history?.browser ?? "")
    }
    private func copy(_ items: [TabWorkspaceItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.url).joined(separator: "\n"), forType: .string)
        model.setMessage(items.count == 1 ? "URL copied." : "Copied \(items.count) URLs.")
    }
    private func closeSelected() {
        let tabs = selectedTabs
        guard !tabs.isEmpty else { return }
        if tabs.count == 1 { model.closeTabs(tabs) }
        else { pendingAction = PendingAction(title: "Close \(tabs.count) browser tabs?", detail: "Unsaved tabs will not be added to your library. Use Save & close to keep them.", perform: { model.closeTabs(tabs) }) }
    }
    private func confirmDelete(_ links: [SavedLink]) {
        pendingAction = PendingAction(title: "Delete \(links.count) saved \(links.count == 1 ? "link" : "links")?", detail: "Their saved notes and tags will also be removed. Browser tabs stay open.", perform: { app.deleteLinks(ids: Set(links.map(\.id))) })
    }
    private func escape() {
        if showingActions { showingActions = false }
        else if !model.markedIDs.isEmpty { model.markedIDs = [] }
        else { model.close?() }
    }
}

private struct WorkspaceCommand: Identifiable {
    let id: String; let title: String; let icon: String; let shortcut: String; let enabled: Bool; let perform: () -> Void
    init(_ id: String, _ title: String, _ icon: String, _ shortcut: String = "", enabled: Bool = true, perform: @escaping () -> Void) {
        self.id = id; self.title = title; self.icon = icon; self.shortcut = shortcut; self.enabled = enabled; self.perform = perform
    }
}
private struct WorkspaceActionMenu: View {
    let commands: [WorkspaceCommand]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    private var filtered: [WorkspaceCommand] { commands.filter { query.isEmpty || $0.title.localizedStandardContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search actions…", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if filtered.indices.contains(selected) { run(filtered[selected]) } }
                    .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
                    .onKeyPress(.downArrow) { selected = min(max(0, filtered.count - 1), selected + 1); return .handled }
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }.font(.system(size: 12)).padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { offset, command in
                            Button { run(command) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: command.icon).frame(width: 18).foregroundStyle(Color.sage)
                                    Text(command.title)
                                    Spacer()
                                    Text(command.shortcut).foregroundStyle(Color.muted)
                                }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 10)
                                    .background(selected == offset ? Color.sage.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).disabled(!command.enabled).id(offset)
                        }
                        if filtered.isEmpty { Text("No matching actions").font(.system(size: 11)).foregroundStyle(Color.muted).padding(20) }
                    }.padding(7)
                }.frame(height: min(340, CGFloat(max(1, filtered.count)) * 36 + 14))
                    .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
        }.frame(width: 350).background(Color.raised, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.line))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 5)
            .task { await Task.yield(); focused = true }
            .onChange(of: query) { _, _ in selected = 0 }
    }
    private func run(_ command: WorkspaceCommand) { guard command.enabled else { return }; dismiss(); command.perform() }
}

private struct WorkspaceLinkEditor: View {
    @ObservedObject var app: AppModel
    @State var link: SavedLink
    @State private var tagInput = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeading("Keep a little context.", subtitle: link.domain)
            TextField("Title", text: $link.title).textFieldStyle(.roundedBorder)
            fieldLabel("NOTE")
            TextEditor(text: $link.note).focused($noteFocused).font(.system(size: 13))
                .scrollContentBackground(.hidden).padding(8).frame(height: 110).nestSurface(radius: 10)
            fieldLabel("TAGS")
            TagEditor(tags: $link.tags, input: $tagInput, suggestions: app.allTags)
            if let error = app.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text("⌘↵ save · Esc cancel").font(.system(size: 10)).foregroundStyle(Color.muted)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.plain)
                Button(saving ? "Saving…" : "Save") {
                    link.tags = SavedLink.normalizedTags(link.tags + SavedLink.parseTags(tagInput)); saving = true
                    Task { if await app.saveWorkspaceLink(link) { dismiss() }; saving = false }
                }.buttonStyle(SageButton()).keyboardShortcut(.return, modifiers: .command).disabled(saving)
            }
        }.padding(26).frame(width: 500).background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
            .interactiveDismissDisabled().onAppear { noteFocused = true }
    }
}
private extension View {
    @ViewBuilder func workspaceJumpShortcut(_ index: Int) -> some View {
        if index < 9 { keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) }
        else { self }
    }
}
