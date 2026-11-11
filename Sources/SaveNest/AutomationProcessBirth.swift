import Darwin

/// Kernel start time distinguishes process lifetimes even when macOS reuses a PID.
struct AutomationProcessBirth: Equatable, Sendable {
    let processID: pid_t
    let seconds: UInt64
    let microseconds: UInt64

    var referenceComponent: String { "\(processID)|\(seconds)|\(microseconds)" }

    static func read(_ processID: pid_t) -> Self? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(processID), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Self(processID: processID, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func matches(_ expected: Self?, processID: pid_t) -> Bool {
        guard let expected, expected.processID == processID, let current = read(processID) else { return false }
        return current == expected
    }
}
