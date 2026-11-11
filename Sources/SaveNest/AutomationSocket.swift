import Foundation
import Darwin
import SaveNestCore

struct AutomationSocketRequest: Codable, Sendable {
    let id: String
    let token: String
    let tool: String
    let arguments: [String: AutomationValue]
}

struct AutomationSocketResponse: Codable, Sendable {
    struct Failure: Codable, Sendable { let code: String; let message: String }
    let id: String
    var result: [String: AutomationValue]?
    var error: Failure?
}

/// One bounded request per connection. The read source stays alive while a tool
/// runs, so a disconnected client cancels its remaining work.
final class AutomationSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.savenest.automation.socket")
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var path: String?
    // Mutable state is confined to queue; cross-queue closures only retain identity.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var task: Task<Void, Never>?
        var received = false
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    func start(path: String, handler: @escaping @MainActor @Sendable (AutomationSocketRequest) async -> AutomationSocketResponse) throws {
        try queue.sync {
            guard listener == nil else { return }
            var address = sockaddr_un()
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketFailure("The AI connection path is too long.") }
            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else {
                    throw SocketFailure("The AI connection path is not a private socket.")
                }
                guard unlink(path) == 0 else { throw SocketFailure("Could not replace the old AI connection socket.") }
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketFailure("Could not create the AI connection.") }
            var keep = false
            defer { if !keep { Darwin.close(fd); unlink(path) } }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { throw SocketFailure("Could not start the private AI connection.") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnections(fd, handler: handler) }
            source.setCancelHandler { Darwin.close(fd) }
            listener = source; self.path = path; keep = true; source.resume()
        }
    }

    func stop() {
        queue.sync {
            for fd in Array(connections.keys) { finish(fd) }
            listener?.cancel(); listener = nil
            if let path { unlink(path) }; path = nil
        }
    }

    private func acceptConnections(_ listenerFD: Int32, handler: @escaping @MainActor @Sendable (AutomationSocketRequest) async -> AutomationSocketResponse) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard connections.count < 16, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(fd: fd, source: source)
            connections[fd] = connection
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.read(connection, handler: handler)
            }
            source.setCancelHandler { Darwin.close(fd) }; source.resume()
            queue.asyncAfter(deadline: .now() + 180) { [weak self, weak connection] in
                guard let self, let connection, self.connections[fd] === connection else { return }
                self.finish(fd)
            }
        }
    }

    private func read(_ connection: Connection, handler: @escaping @MainActor @Sendable (AutomationSocketRequest) async -> AutomationSocketResponse) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = recv(connection.fd, &bytes, bytes.count, 0)
        if count == 0 { finish(connection.fd); return }
        guard count > 0 else { if errno != EAGAIN && errno != EINTR { finish(connection.fd) }; return }
        guard !connection.received else { finish(connection.fd); return }
        connection.buffer.append(contentsOf: bytes.prefix(count))
        guard connection.buffer.count <= 1_048_576 else { finish(connection.fd); return }
        guard let newline = connection.buffer.firstIndex(of: 10) else { return }
        guard newline == connection.buffer.count - 1,
              let request = try? JSONDecoder().decode(AutomationSocketRequest.self, from: connection.buffer.prefix(upTo: newline)),
              !request.id.isEmpty, request.id.count <= 128, request.token.count <= 256 else { finish(connection.fd); return }
        connection.received = true; connection.buffer.removeAll()
        connection.task = Task { @MainActor [weak self, weak connection] in
            let response = await handler(request)
            guard !Task.isCancelled, let self, let connection, var data = try? JSONEncoder().encode(response) else { return }
            if data.count > 15 * 1024 * 1024 {
                let failure = AutomationSocketResponse(id: request.id, error: .init(code: "response_too_large", message: "Request fewer records or a smaller search limit. For mutations, inspect current state before starting another action."))
                data = (try? JSONEncoder().encode(failure)) ?? Data()
            }
            data.append(10)
            self.queue.async { [weak self, weak connection] in
                guard let self, let connection, self.connections[connection.fd] === connection else { return }
                // Responses are bounded by pagination; wait briefly for slow readers.
                _ = fcntl(connection.fd, F_SETFL, 0)
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(connection.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                data.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let count = send(connection.fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                        if count <= 0 { break }; sent += count
                    }
                }
                self.finish(connection.fd)
            }
        }
    }
    private func finish(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.task?.cancel(); connection.source.cancel()
    }
    struct SocketFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

enum AutomationPrivateFiles {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              chmod(url.path, 0o700) == 0 else { throw AutomationSocket.SocketFailure("AI connection storage must be a private folder owned by you.") }
    }
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AutomationSocket.SocketFailure("Could not create private AI connection storage.") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard count > 0 else { throw AutomationSocket.SocketFailure("Could not save the AI connection.") }; written += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw AutomationSocket.SocketFailure("Could not save the AI connection.") }
    }
    static func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AutomationSocket.SocketFailure("Could not read private AI connection storage.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 1_048_576 else { throw AutomationSocket.SocketFailure("AI connection storage has unsafe permissions.") }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
}
