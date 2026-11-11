import Foundation
import CryptoKit

/// Markdown is authoritative. The index stores associations, never a second copy of saved notes.
public final class NoteFiles {
    public struct Failure: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
    public struct Configuration: Codable {
        public var vault: String
        public var folder: String
    }
    private struct Document: Codable {
        var id: String
        var identity: String
        var url: String
        var title: String
        var vault: String
        var relativePath: String
        var created: Bool
    }
    private struct Draft: Codable { var text: String; var revision: String }
    private struct Index: Codable {
        var configuration: Configuration?
        var documents: [String: Document] = [:]
    }
    public let storage: URL
    private var index: Index
    private let manager = FileManager.default
    public var configuration: Configuration? { index.configuration }
    public static let maximumCharacters = 100_000

    public init(storage: URL) throws {
        self.storage = storage
        let file = storage.appendingPathComponent("notes-index.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: file)) }
            catch { throw Failure(message: "The note index couldn’t be opened. Your vault files are unchanged.") }
        } else { index = Index() }
    }

    public func configure(vault: URL, folder: String? = nil) throws {
        let root = vault.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: root.appendingPathComponent(".obsidian").path, isDirectory: &directory), directory.boolValue else {
            throw Failure(message: "Choose an Obsidian vault folder containing .obsidian.")
        }
        var destination = folder ?? "SaveNest"
        if folder == nil, let data = try? Data(contentsOf: root.appendingPathComponent(".obsidian/app.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           settings["newFileLocation"] as? String == "folder", let configured = settings["newFileFolderPath"] as? String, !configured.isEmpty {
            destination = configured
        }
        _ = try safeURL(root: root.path, relative: destination, allowRoot: true)
        index.configuration = Configuration(vault: root.path, folder: destination)
        try persist()
    }

    public func changeFolder(_ folder: URL) throws {
        guard let configuration else { throw Failure(message: "Choose an Obsidian vault first.") }
        let root = URL(fileURLWithPath: configuration.vault).standardizedFileURL
        let candidate = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { throw Failure(message: "Choose a folder inside this vault.") }
        let relative = candidate.path == root.path ? "" : String(candidate.path.dropFirst(root.path.count + 1))
        try configure(vault: root, folder: relative)
    }

    public func load(url: String, title: String) throws -> [String: Any] {
        guard Library.validatedURL(url) != nil else { throw Failure(message: "This page address isn’t supported.") }
        guard let configuration else { throw Failure(message: "Choose an Obsidian vault to start writing.") }
        let identity = Library.identity(url)
        var document = index.documents.values.first { $0.identity == identity }
        if document == nil {
            document = try discover(identity: identity, configuration: configuration)
        }
        if document == nil {
            let id = UUID().uuidString.lowercased()
            let filename = try availableFilename(title: title, id: id, configuration: configuration)
            document = Document(id: id, identity: identity, url: url, title: title, vault: configuration.vault,
                                relativePath: joined(configuration.folder, filename), created: false)
        }
        let value = document!
        index.documents[value.id] = value
        try persist()
        var result = try snapshot(value)
        if let draft = try readDraft(value.id) {
            result["diskText"] = result["text"]
            result["diskRevision"] = result["revision"]
            result["text"] = draft.text
            result["revision"] = draft.revision
            result["recovered"] = true
            result["conflict"] = draft.revision != (result["diskRevision"] as? String)
        }
        return result
    }

    public func check(id: String, revision: String) throws -> [String: Any] {
        let document = try known(id)
        var result = try snapshot(document)
        result["changed"] = result["revision"] as? String != revision
        return result
    }

    public func save(id: String, text: String, revision: String) throws -> [String: Any] {
        try validateText(text)
        var document = try known(id)
        // Persist recovery before any potentially failing vault operation.
        try saveDraft(id: id, text: text, revision: revision)
        let file = try location(document)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try location(document)
        var result: [String: Any] = [:]
        var operationError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                _ = try self.location(document)
                let current = try self.disk(coordinated)
                guard current.revision == revision else {
                    result = try self.snapshot(document)
                    result["conflict"] = true
                    return
                }
                guard !(document.created && !current.exists) else {
                    throw Failure(message: "This note moved or was deleted. Locate it or save your text as a copy.")
                }
                try Data(text.utf8).write(to: coordinated, options: .atomic)
                document.created = true
                self.index.documents[id] = document
                try self.persist()
                try self.clearDraft(id)
                result = try self.snapshot(document)
            } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
        return result
    }

    public func saveDraft(id: String, text: String, revision: String) throws {
        _ = try known(id)
        try validateText(text)
        try prepareStorage()
        let data = try JSONEncoder().encode(Draft(text: text, revision: revision))
        try data.write(to: draftURL(id), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL(id).path)
    }

    public func discardDraft(id: String) throws {
        _ = try known(id)
        try clearDraft(id)
    }

    public func saveCopy(id: String, text: String) throws -> [String: Any] {
        try validateText(text)
        let original = try known(id)
        let newID = UUID().uuidString.lowercased()
        let folder = (original.relativePath as NSString).deletingLastPathComponent
        let config = Configuration(vault: original.vault, folder: folder)
        let filename = try availableFilename(title: original.title + " (copy)", id: newID, configuration: config)
        let copy = Document(id: newID, identity: "pending-copy:" + original.identity, url: original.url, title: original.title,
                            vault: original.vault, relativePath: joined(folder, filename), created: false)
        index.documents[newID] = copy
        try persist()
        let body = replacingNoteID(in: text, with: newID)
        let result = try save(id: newID, text: body, revision: "missing")
        if result["conflict"] as? Bool != true {
            // Future opens follow the user's preserved copy, while the original remains in the vault.
            index.documents[id]?.identity = "detached:" + original.identity
            index.documents[newID]?.identity = original.identity
            try persist()
            try clearDraft(id)
        }
        return result
    }

    public func locate(id: String, file: URL) throws -> [String: Any] {
        var document = try known(id)
        let root = URL(fileURLWithPath: document.vault).standardizedFileURL
        let candidate = file.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"), candidate.pathExtension.lowercased() == "md" else {
            throw Failure(message: "Choose this note’s Markdown file inside its original vault.")
        }
        let contents = try disk(candidate)
        guard contents.exists, frontmatter(contents.text)["savenest_id"] == document.id else {
            throw Failure(message: "This file belongs to another note. Choose the original Savenest note.")
        }
        document.relativePath = String(candidate.path.dropFirst(root.path.count + 1))
        document.created = true
        index.documents[id] = document
        try persist()
        return try snapshot(document)
    }

    public func fileURL(id: String) throws -> URL { try location(known(id)) }

    private func snapshot(_ document: Document) throws -> [String: Any] {
        let file = try location(document)
        let current = try disk(file)
        return ["documentId": document.id, "text": current.exists ? current.text : template(document),
                "revision": current.revision, "path": file.path, "exists": current.exists,
                "missing": document.created && !current.exists, "url": document.url, "title": document.title,
                "vaultName": URL(fileURLWithPath: document.vault).lastPathComponent,
                "folder": (document.relativePath as NSString).deletingLastPathComponent]
    }

    private func known(_ id: String) throws -> Document {
        guard let value = index.documents[id] else { throw Failure(message: "This note session expired. Reopen the page.") }
        return value
    }
    private func location(_ document: Document) throws -> URL { try safeURL(root: document.vault, relative: document.relativePath) }

    private func safeURL(root: String, relative: String, allowRoot: Bool = false) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
              !relative.split(separator: "/").contains(".obsidian"), !relative.contains("\0") else {
            throw Failure(message: "Choose a notes folder inside the vault.")
        }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: rootURL.appendingPathComponent(".obsidian").path, isDirectory: &directory), directory.boolValue else {
            throw Failure(message: "This vault is unavailable. Reconnect it before saving; your draft is kept in Savenest.")
        }
        guard rootURL.resolvingSymlinksInPath().path == rootURL.path else {
            throw Failure(message: "The vault location changed. Choose the vault again.")
        }
        let file = rootURL.appendingPathComponent(relative).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath()
        guard (allowRoot && resolved.path == rootURL.path) || resolved.path.hasPrefix(rootURL.path + "/"),
              file.path == resolved.path else { throw Failure(message: "Notes cannot follow symbolic links outside their destination.") }
        return file
    }

    private func disk(_ file: URL) throws -> (text: String, revision: String, exists: Bool) {
        guard manager.fileExists(atPath: file.path) else { return ("", "missing", false) }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumCharacters * 4 else {
            throw Failure(message: "This note is too large for the editor. Open it in Obsidian.")
        }
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8), text.count <= Self.maximumCharacters else {
            throw Failure(message: "This note needs to be opened in Obsidian; Savenest supports UTF-8 notes up to 100,000 characters.")
        }
        return (text, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), true)
    }

    private func validateText(_ text: String) throws {
        guard text.count <= Self.maximumCharacters else { throw Failure(message: "This note reached the 100,000-character editor limit. Your existing file is unchanged.") }
    }
    private func availableFilename(title: String, id: String, configuration: Configuration) throws -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\0")
        var name = title.components(separatedBy: invalid).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        name = String(name.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "Untitled page" }
        var filename = name + ".md"
        let proposed = joined(configuration.folder, filename)
        if manager.fileExists(atPath: try safeURL(root: configuration.vault, relative: proposed).path) ||
            index.documents.values.contains(where: { $0.vault == configuration.vault && $0.relativePath.lowercased() == proposed.lowercased() }) {
            filename = name + " " + id.prefix(8) + ".md"
        }
        return filename
    }
    private func template(_ document: Document) -> String {
        "---\nsavenest_id: \(quoted(document.id))\nsource: \(quoted(document.url))\n---\n\n# \(document.title.replacingOccurrences(of: "\n", with: " "))\n\n"
    }
    private func quoted(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    private func replacingNoteID(in text: String, with id: String) -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        let field = "savenest_id: " + quoted(id)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            return "---\n\(field)\n---\n\n" + text
        }
        if let existing = (1..<end).first(where: { index in
            guard let colon = lines[index].firstIndex(of: ":") else { return false }
            return lines[index][..<colon].trimmingCharacters(in: .whitespaces) == "savenest_id"
        }) { lines[existing] = field }
        else { lines.insert(field, at: end) }
        return lines.joined(separator: newline)
    }
    private func joined(_ folder: String, _ filename: String) -> String { folder.isEmpty ? filename : folder + "/" + filename }
    private func draftURL(_ id: String) -> URL { storage.appendingPathComponent("draft-\(id).json") }
    private func readDraft(_ id: String) throws -> Draft? {
        let file = draftURL(id)
        guard manager.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Draft.self, from: Data(contentsOf: file))
    }
    private func clearDraft(_ id: String) throws {
        if manager.fileExists(atPath: draftURL(id).path) { try manager.removeItem(at: draftURL(id)) }
    }
    private func prepareStorage() throws {
        try manager.createDirectory(at: storage, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.path)
    }
    private func persist() throws {
        try prepareStorage()
        try JSONEncoder().encode(index).write(to: storage.appendingPathComponent("notes-index.json"), options: .atomic)
    }
    private func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
        }
        return result
    }
    private func discover(identity: String, configuration: Configuration) throws -> Document? {
        let directory = try safeURL(root: configuration.vault, relative: configuration.folder, allowRoot: true)
        guard manager.fileExists(atPath: directory.path) else { return nil }
        // Recovery discovery is deliberately bounded. Normal reopens use the persisted index;
        // do not read an entire vault (or entire note bodies) on the app's main actor.
        let deadline = Date().addingTimeInterval(0.15)
        guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        var checked = 0
        while checked < 256, Date() < deadline, let file = files.nextObject() as? URL {
            checked += 1
            guard file.pathExtension.lowercased() == "md", file.resolvingSymlinksInPath().path == file.path,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey]),
                  values.isRegularFile == true, values.ubiquitousItemDownloadingStatus != .notDownloaded,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let header = try? handle.read(upToCount: 8_192)
            try? handle.close()
            guard let header else { continue }
            let fields = frontmatter(String(decoding: header, as: UTF8.self))
            guard let source = fields["source"], Library.identity(source) == identity,
                  let id = fields["savenest_id"], UUID(uuidString: id) != nil else { continue }
            return Document(id: id, identity: identity, url: source, title: file.deletingPathExtension().lastPathComponent,
                            vault: configuration.vault, relativePath: joined(configuration.folder, file.lastPathComponent), created: true)
        }
        return nil
    }
}
