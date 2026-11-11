import SwiftUI
import SaveNestCore

struct AddLinkView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var collection = "Inbox"
    @State private var note = ""
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var saving = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeading("A good find.", subtitle: "Give that link a little home.")
            VStack(alignment: .leading, spacing: 8) { fieldLabel("WEB ADDRESS"); TextField("https://…", text: $url).focused($focused) }
            VStack(alignment: .leading, spacing: 8) { fieldLabel("TITLE (OPTIONAL)"); TextField("Something worth keeping", text: $title) }
            VStack(alignment: .leading, spacing: 8) { fieldLabel("NOTE"); NoteEditor(text: $note, height: 90) }
            VStack(alignment: .leading, spacing: 8) { fieldLabel("TAGS"); TagEditor(tags: $tags, input: $tagInput, suggestions: model.allTags) }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("Paste URL") { if let value = NSPasteboard.general.string(forType: .string) { url = value.trimmingCharacters(in: .whitespacesAndNewlines) } }.buttonStyle(QuietButton())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.plain)
                Button(saving ? "Saving…" : "Save link") { saving = true; Task { if await model.add(url: url, title: title, collection: collection, note: note, tags: tags + SavedLink.parseTags(tagInput)) { dismiss() }; saving = false } }.buttonStyle(SageButton()).keyboardShortcut(.return, modifiers: .command).disabled(saving || Library.validatedURL(url) == nil)
            }.padding(.top, 8)
        }.textFieldStyle(.roundedBorder).padding(32).frame(width: 470).background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
            .onAppear { focused = true; if model.library.collections.contains(model.filter) { collection = model.filter } }
    }
}
struct LinkDetailView: View {
    @ObservedObject var model: AppModel
    @State var link: SavedLink
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var tagsText = ""
    @State private var saving = false
    @State private var originalRevision: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                DomainIcon(domain: link.domain, url: link.url, iconURL: link.iconURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(link.domain).font(.system(size: 18, weight: .medium))
                    Text("Saved from \(link.browser) · \(link.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 11)).foregroundStyle(Color.muted)
                }
                Spacer()
                Button { model.open(link) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(NestIconButton()).help("Open link")
            }
            VStack(alignment: .leading, spacing: 8) { fieldLabel("TITLE"); TextField("Title", text: $link.title).textFieldStyle(.roundedBorder) }
            Text(link.url).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(3).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("A NOTE TO YOUR FUTURE SELF")
                NoteEditor(text: $link.note)
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("TAGS")
                TagEditor(tags: $link.tags, input: $tagsText, suggestions: model.allTags)
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Menu {
                    Button("Copy link") { model.copy(link) }
                    Button(link.isArchived ? "Restore to library" : "Archive link") { if model.archive(link) { dismiss() } }
                    if link.isArchived {
                        Divider()
                        Button("Delete permanently…", role: .destructive) { confirmingDelete = true }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 30)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.plain)
                Button(saving ? "Saving…" : "Save changes") { link.tags = SavedLink.normalizedTags(link.tags + SavedLink.parseTags(tagsText)); saving = true; Task { if await model.update(link, expectedRevision: originalRevision) { dismiss() }; saving = false } }.buttonStyle(SageButton()).keyboardShortcut(.return, modifiers: .command).disabled(saving)
            }
        }.padding(32).frame(width: 510).background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
            .onAppear { if originalRevision == nil { originalRevision = AutomationLibrary.revision(link) } }
            .interactiveDismissDisabled()
            .alert("Delete this link?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { model.delete(link); dismiss() }
            } message: { Text("This permanently removes the link and its note from Savenest.") }
    }
}

struct TabSelectionView: View {
    @ObservedObject var model: AppModel
    let draftID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading("Choose what stays.", subtitle: "Select the tabs you want to save. Nothing closes in your browser.")
            if let draft = model.tabSelection, draft.id == draftID {
                HStack {
                    Button("Select all") { model.updateTabSelection(Set(draft.links.map(\.id))) }.buttonStyle(.link)
                    Button("Select none") { model.updateTabSelection([]) }.buttonStyle(.link)
                    Spacer()
                    Text("\(draft.selected.count) selected").font(.system(size: 11)).foregroundStyle(Color.muted)
                }
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(draft.links) { link in
                            Button {
                                var selected = draft.selected
                                if selected.contains(link.id) { selected.remove(link.id) } else { selected.insert(link.id) }
                                model.updateTabSelection(selected)
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: draft.selected.contains(link.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(draft.selected.contains(link.id) ? Color.sage : Color.muted)
                                    DomainIcon(domain: link.domain, url: link.url, iconURL: link.iconURL)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(link.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(link.domain).font(.system(size: 10)).foregroundStyle(Color.muted).lineLimit(1)
                                    }
                                    Spacer()
                                }.padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(CGFloat(draft.links.count) * 58, 360))
                    .nestSurface()
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelTabSelection() }.keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    Button(draft.selected.count == 1 ? "Save tab" : "Save \(draft.selected.count) tabs") { model.saveTabSelection() }
                        .buttonStyle(SageButton()).keyboardShortcut(.defaultAction).disabled(draft.selected.isEmpty)
                }
            }
        }.padding(28).frame(width: 520).background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case library = "Library"
    case ai = "AI connections"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: "sparkles"
        case .capture: "command"
        case .library: "tray.full"
        case .ai: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.black.rawValue
    @State private var archiveIDs: Set<UUID>?
    @State private var selectedTab = SettingsTab.general
    @State private var tabMoveEdge = Edge.trailing
    var onBack: () -> Void = {}
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 26) {
            if selectedTab != .ai {
                Button { onBack() } label: { Label("All tabs", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                sheetHeading("Make yourself at home.", subtitle: "A few small things, just how you like them.")
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            settingsTabs
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 16) { settingsContent }
                    .id(selectedTab)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: tabMoveEdge)),
                        removal: .opacity.combined(with: .move(edge: tabMoveEdge == .trailing ? .leading : .trailing))
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
            if selectedTab != .ai {
                HStack { NestMark().frame(width: 20, height: 20); Text("Savenest " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")); Spacer(); Text("A small app for a clearer mind.") }.font(.system(size: 10)).foregroundStyle(Color.muted)
            }
        }.padding(32) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
        .alert(archiveIDs.map { "Archive \($0.count) \($0.count == 1 ? "link" : "links")?" } ?? "", isPresented: Binding(get: { archiveIDs != nil }, set: { if !$0 { archiveIDs = nil } }), presenting: archiveIDs) { ids in
            Button("Cancel", role: .cancel) { archiveIDs = nil }
            Button("Archive all") {
                model.setArchived(true, ids: ids)
                archiveIDs = nil
                model.showLibrary?()
            }
        } message: { _ in
            Text("All saved links will move to Archive, including links hidden by filters. Your notes and tags stay with them. You can undo this.")
        }
    }

    private var settingsTabs: some View {
        HStack(spacing: 10) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = selectedTab == tab
                Button {
                    select(tab)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Color.sage : Color.muted)
                            .frame(width: 25, height: 25)
                            .background(selected ? Color.sage.opacity(0.12) : Color.line.opacity(0.28), in: Circle())
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.ink : Color.muted)
                        Spacer(minLength: 0)
                        Circle().fill(Color.sage).frame(width: 5, height: 5).opacity(selected ? 1 : 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(selected ? Color.sage.opacity(0.07) : Color.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Color.sage.opacity(0.28) : Color.line.opacity(0.55)))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func select(_ tab: SettingsTab) {
        guard tab != selectedTab else { return }
        let tabs = SettingsTab.allCases
        let current = tabs.firstIndex(of: selectedTab) ?? 0
        let next = tabs.firstIndex(of: tab) ?? current
        tabMoveEdge = next > current ? .trailing : .leading
        withAnimation(.easeInOut(duration: 0.24)) { selectedTab = tab }
    }

    @ViewBuilder private var settingsContent: some View {
        switch selectedTab {
        case .ai:
            AutomationSettingsView(controller: model.aiConnections, account: model.account)
        case .general:
            appearancePicker
            AppUpdateSettingsView(updater: model.updater)
            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("ANONYMOUS USAGE")
                Toggle("Share anonymous usage counts", isOn: $model.analyticsEnabled)
                Text("Share anonymous action counts with savenest.app. No URLs, titles, notes, tags, account IDs, or device identifiers are included.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                OwnerUsageView(account: model.account)
            }.padding(20).nestSurface()
            Link("Read the privacy policy ↗", destination: URL(string: "https://savenest.app/privacy")!).font(.system(size: 12))
            Button("Account & Pro…") { model.showAccount?() }.buttonStyle(QuietButton())
        case .capture:
            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("CLIPBOARD")
                Toggle("Offer to save copied links", isOn: $model.clipboardEnabled)
                Text("Offers Save or Add note after you copy a new web link. Clipboard contents stay on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                Button("Preview clipboard offer") { model.notify(CaptureNotice(title: "Save copied link?", message: "example.com", clipboardURL: URL(string: "https://example.com/clipboard-preview")!)) }
                    .buttonStyle(.link).font(.system(size: 11))
            }.padding(20).nestSurface()
            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("AUTO-TAGGING")
                Toggle("Suggest tags when saving links", isOn: $model.autoTaggingEnabled)
                Text("Uses titles, websites, and your existing tags. Everything stays on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(20).nestSurface()
            VStack(alignment: .leading, spacing: 15) {
                fieldLabel("KEYBOARD SHORTCUTS")
                Button("Use memorable preset: ⇧⌘K / ⇧⌘N") { model.applyMemorableShortcuts() }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("Show the quick tour") { model.showOnboarding() }.buttonStyle(.link).font(.system(size: 11))
                ForEach(CaptureAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(action.title).font(.system(size: 12, weight: .medium))
                            Spacer()
                            ShortcutRecorder(label: (model.shortcuts[action] ?? action.defaultShortcut).label,
                                onStart: { model.hotkey.unregister() },
                                onRecord: { model.configureShortcut($0, for: action) }).frame(width: 145, height: 30)
                            Button { model.configureShortcut(action.defaultShortcut, for: action) } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain).foregroundStyle(Color.muted).help("Reset \(action.title) shortcut")
                        }
                        if let error = model.shortcutErrors[action] { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
                    }
                }
                Text("Click a shortcut, then press a new combination. Escape cancels.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted)
                Button("Preview popup") { model.notify(CaptureError.noTabs.notice) }.buttonStyle(.link).font(.system(size: 11))
            }.padding(20).nestSurface()
            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("AFTER SAVING")
                Toggle("Close source tab after a successful save", isOn: $model.closeAfterQuickSave)
                Text("Applies to Save link and Save with a note. Bulk saves never close tabs.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted)
            }.padding(20).nestSurface()
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("BROWSERS & PRIVACY")
                Text("Savenest reads browser tabs only when you use a capture or tab tool.")
                    .font(.system(size: 11)).foregroundStyle(Color.muted)
                Button("Open Automation Settings ↗") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }.buttonStyle(.link).font(.system(size: 11))
            }
        case .library:
            ObsidianNotesSettings(notes: model.notes)
            VStack(alignment: .leading, spacing: 13) {
                fieldLabel("YOUR LIBRARY")
                Button("Archive all links…") { archiveIDs = model.activeIDs }
                    .buttonStyle(QuietButton()).disabled(model.activeIDs.isEmpty)
                HStack {
                    Button("Export backup…") { model.exportLibrary() }.buttonStyle(QuietButton())
                    Button("Import backup…") { model.importLibrary() }.buttonStyle(QuietButton())
                    Spacer()
                    Button("Show in Finder") { model.revealLibrary() }.buttonStyle(.link).font(.system(size: 11))
                }
            }.padding(20).nestSurface()
        }
    }

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("APPEARANCE")
            HStack(spacing: 12) {
                ForEach(AppAppearance.allCases) { option in
                    Button { appearance = option.rawValue } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            appearancePreview(option)
                            HStack {
                                Text(option.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Image(systemName: appearance == option.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(appearance == option.rawValue ? Color.sage : Color.muted.opacity(0.5))
                            }
                            Text(option.subtitle).font(.system(size: 10)).foregroundStyle(Color.muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(appearance == option.rawValue ? Color.sage.opacity(0.6) : Color.line.opacity(0.7), lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel("\(option.title) appearance")
                        .accessibilityValue(appearance == option.rawValue ? "Selected" : "Not selected")
                        .accessibilityAddTraits(appearance == option.rawValue ? .isSelected : [])
                }
            }
            Text("Applies throughout Savenest. Your choice is remembered.").font(.system(size: 11)).foregroundStyle(Color.muted)
        }
    }

    private func appearancePreview(_ option: AppAppearance) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(option.previewInk.opacity(0.2)).frame(width: 3, height: 3) }
                }
                Capsule().fill(option.previewInk.opacity(0.7)).frame(width: 55, height: 4)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(option.previewAccent.opacity(0.15)).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(option.previewInk.opacity(0.45)).frame(height: 3)
                        Capsule().fill(option.previewInk.opacity(0.18)).frame(width: 40, height: 3)
                    }
                }.padding(7).background(option.previewSurface, in: RoundedRectangle(cornerRadius: 7))
            }.frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                Image(systemName: "tray.fill").foregroundStyle(option.previewAccent)
                Image(systemName: "plus").foregroundStyle(option.previewInk.opacity(0.4))
            }.font(.system(size: 9)).padding(7).background(option.previewSurface, in: Capsule())
        }.padding(12).frame(height: 90).background(option.previewPaper, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct TabCleanupWebsitesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var expanded: Set<String> = []

    private var availableDomains: [String] {
        let configured = Set(model.tabCleanupDomains)
        return Array(Set(model.cleanupOpenTabs.compactMap { TabCleanupPlanner.normalizedDomain($0.domain) }))
            .filter { !configured.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading("Cleanup websites", subtitle: "Only tabs from websites in this list can be closed by website cleanup.")
            HStack(spacing: 8) {
                TextField("example.com", text: $domain).textFieldStyle(.roundedBorder).onSubmit(addDomain)
                Button("Add") { addDomain() }.buttonStyle(SageButton()).disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.tabCleanupDomains.isEmpty {
                        Text("No websites selected yet.").font(.system(size: 12)).foregroundStyle(Color.muted).padding(.vertical, 14)
                    }
                    ForEach(model.tabCleanupDomains, id: \.self) { item in
                        let matches = TabCleanupPlanner.domainCandidates(model.cleanupOpenTabs, domains: [item])
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(item) }, set: { value in
                            if value { expanded.insert(item) } else { expanded.remove(item) }
                        })) {
                            if matches.isEmpty {
                                Text("No matching tabs are open.").font(.system(size: 10)).foregroundStyle(Color.muted).padding(.top, 8)
                            } else {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(matches) { tab in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tab.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                            Text(tab.url).font(.system(size: 9)).foregroundStyle(Color.muted).lineLimit(1)
                                        }
                                    }
                                }.padding(.top, 8)
                            }
                        } label: {
                            HStack {
                                Text(item).font(.system(size: 12, weight: .medium))
                                Text("\(matches.count) open").font(.system(size: 10)).foregroundStyle(Color.muted)
                                Spacer()
                                Button { model.removeCleanupDomain(item) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(Color.muted).help("Remove \(item)")
                            }
                        }.padding(12).nestSurface(radius: 11)
                    }
                    if !availableDomains.isEmpty {
                        fieldLabel("ADD FROM OPEN TABS").padding(.top, 10)
                        ForEach(availableDomains, id: \.self) { item in
                            Button { _ = model.addCleanupDomain(item) } label: {
                                HStack {
                                    Text(item).font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(Color.sage)
                                }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain).nestSurface(radius: 10)
                        }
                    }
                }
            }.frame(height: 330)
            HStack {
                Button { model.refreshCleanupOpenTabs() } label: { Label("Refresh open tabs", systemImage: "arrow.clockwise") }
                    .buttonStyle(.link).disabled(model.isCleaningTabs)
                if model.isCleaningTabs { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SageButton()).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560).background(Color.paper).foregroundStyle(Color.ink).nestAppearance()
    }

    private func addDomain() {
        if model.addCleanupDomain(domain) { domain = "" }
    }
}

func fieldLabel(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Color.muted) }
func sheetHeading(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
        Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.6)
        Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.muted)
    }
}
