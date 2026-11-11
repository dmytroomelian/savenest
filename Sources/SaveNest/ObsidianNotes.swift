import AppKit
import SwiftUI
import SaveNestCore
import UniformTypeIdentifiers

@MainActor
final class ObsidianNotes: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var destination = "Choose a vault to start writing."
    private let preview: Bool
    private let lab: Bool
    private let storage: URL
    private var service: NoteFiles?
    private var startupError: Error?

    init(preview: Bool, lab: Bool = false) {
        self.preview = preview
        self.lab = lab
        if preview {
            storage = FileManager.default.temporaryDirectory.appendingPathComponent("SaveNest-reader-preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            storage = AppRuntime.supportDirectory.appendingPathComponent(lab ? "ReaderNotes-Lab" : "ReaderNotes", isDirectory: true)
        }
        do { service = try NoteFiles(storage: storage) }
        catch { startupError = error }
        updateStatus()
    }

    func status() -> [String: Any] {
        let config = service?.configuration
        var result: [String: Any] = ["configured": config != nil, "vaultName": config.map { URL(fileURLWithPath: $0.vault).lastPathComponent } ?? "",
            "folder": config?.folder ?? "", "destination": destination, "preview": preview, "readerTest": lab]
        if let error = startupError { result["error"] = error.localizedDescription }
        return result
    }

    func chooseVault() throws -> [String: Any] {
        let store = try available()
        if preview {
            let vault = storage.appendingPathComponent("Sample vault", isDirectory: true)
            let settings = vault.appendingPathComponent(".obsidian", isDirectory: true)
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
            try Data(#"{"newFileLocation":"folder","newFileFolderPath":"Rough notes"}"#.utf8).write(to: settings.appendingPathComponent("app.json"), options: .atomic)
            try store.configure(vault: vault)
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose your Obsidian vault"
            panel.message = "Savenest writes Markdown directly into your vault. Choose the folder containing .obsidian."
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return status() }
            try store.configure(vault: url)
        }
        updateStatus()
        return status()
    }

    func chooseFolder() throws -> [String: Any] {
        let store = try available()
        guard let config = store.configuration else { return try chooseVault() }
        if preview { return status() }
        let panel = NSOpenPanel()
        panel.title = "Choose a notes folder"
        panel.message = "New page notes will go here. Existing notes stay where they are."
        panel.directoryURL = URL(fileURLWithPath: config.vault)
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return status() }
        try store.changeFolder(url)
        updateStatus()
        return status()
    }

    func load(url: String, title: String) throws -> [String: Any] { try available().load(url: url, title: title) }
    func save(id: String, text: String, revision: String) throws -> [String: Any] { try available().save(id: id, text: text, revision: revision) }
    func draft(id: String, text: String, revision: String) throws { try available().saveDraft(id: id, text: text, revision: revision) }
    func discardDraft(id: String) throws { try available().discardDraft(id: id) }
    func check(id: String, revision: String) throws -> [String: Any] { try available().check(id: id, revision: revision) }
    func saveCopy(id: String, text: String) throws -> [String: Any] { try available().saveCopy(id: id, text: text) }

    func locate(id: String) throws -> [String: Any] {
        let store = try available()
        if preview { return try store.check(id: id, revision: "") }
        let current = try store.fileURL(id: id)
        let panel = NSOpenPanel()
        panel.title = "Locate this note"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = current.deletingLastPathComponent()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let file = panel.url else { return ["cancelled": true] }
        return try store.locate(id: id, file: file)
    }

    func open(id: String) throws {
        let file = try available().fileURL(id: id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw NoteFiles.Failure(message: "Write something first to create this note.") }
        if preview { NSWorkspace.shared.activateFileViewerSelecting([file]); return }
        var components = URLComponents()
        components.scheme = "obsidian"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        guard let url = components.url, NSWorkspace.shared.open(url) else { throw NoteFiles.Failure(message: "Obsidian could not open. Install Obsidian or reveal this note in Finder.") }
    }

    func reveal(id: String) throws { NSWorkspace.shared.activateFileViewerSelecting([try available().fileURL(id: id)]) }

    private func available() throws -> NoteFiles {
        if let error = startupError { throw error }
        guard let service else { throw NoteFiles.Failure(message: "Notes are unavailable. Quit and reopen Savenest.") }
        return service
    }
    private func updateStatus() {
        configured = service?.configuration != nil
        if let config = service?.configuration {
            destination = URL(fileURLWithPath: config.vault).appendingPathComponent(config.folder).path
        }
    }
}

struct ObsidianNotesSettings: View {
    @ObservedObject var notes: ObsidianNotes
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notes & Obsidian").font(.system(size: 15, weight: .semibold))
            Text("Read a page and write beside it. Your notes are ordinary Markdown files in your vault.")
                .font(.system(size: 12)).foregroundStyle(Color.muted)
            Text(notes.destination).font(.system(size: 11)).foregroundStyle(Color.muted).textSelection(.enabled)
            HStack {
                Button(notes.configured ? "Change vault…" : "Choose vault…") { perform { _ = try notes.chooseVault() } }.buttonStyle(QuietButton())
                if notes.configured { Button("Change notes folder…") { perform { _ = try notes.chooseFolder() } }.buttonStyle(QuietButton()) }
            }
            Text("Folder changes apply to new notes. Existing notes and quick notes stay where they are.")
                .font(.system(size: 11)).foregroundStyle(Color.muted)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }.padding(20).nestSurface()
    }
    private func perform(_ operation: () throws -> Void) { do { try operation(); error = nil } catch { self.error = error.localizedDescription } }
}
