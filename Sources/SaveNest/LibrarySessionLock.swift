import Foundation
import Darwin

/// Native and Electron hosts share one library. Keep one writer alive at a time.
final class LibrarySessionLock {
    private let descriptor: Int32
    init() throws {
        let folder = AppRuntime.supportDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        descriptor = Darwin.open(folder.appendingPathComponent("library-session.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw Failure() }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    private struct Failure: LocalizedError {
        var errorDescription: String? { "SaveNest couldn’t lock its library. Quit other copies of SaveNest and try again." }
    }
}
