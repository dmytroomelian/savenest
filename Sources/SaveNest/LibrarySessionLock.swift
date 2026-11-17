import Foundation
import Darwin

/// Native and Electron hosts share one library. Keep one writer alive at a time.
final class LibrarySessionLock {
    private let descriptor: Int32
    init(folder: URL = AppRuntime.supportDirectory) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        descriptor = Darwin.open(folder.appendingPathComponent("library-session.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.unavailable(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw code == EWOULDBLOCK ? Failure.busy : Failure.unavailable(code)
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    enum Failure: LocalizedError, Equatable {
        case busy
        case unavailable(Int32)
        var errorDescription: String? {
            switch self {
            case .busy: return "Savenest is already open. Quit it from its menu bar icon, then reopen this copy."
            case .unavailable: return "Savenest couldn’t access its library folder. Check your Mac’s storage and folder permissions, then try again."
            }
        }
    }
}
