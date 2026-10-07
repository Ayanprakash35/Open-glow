import Darwin

/// Read-only access to the processes running on this Mac, one question per call so callers only
/// pay for what they ask. Any answer may be nil: the process may have exited, or belong to
/// another user (root processes' arguments can't be read).
protocol ProcessTable {
    /// Every process running now, in no particular order.
    func processIDs() -> [pid_t]
    /// The file the process runs, with symlinks resolved.
    func executablePath(of pid: pid_t) -> String?
    /// The process's argv, including argv[0] as it was passed.
    func arguments(of pid: pid_t) -> [String]?
    func parentID(of pid: pid_t) -> pid_t?
}

/// The real process table, through libproc and `sysctl` (public APIs). Measured on an M-series
/// Mac with ~460–500 processes: listing every PID 10–130 µs (the low end back to back, the high
/// end with cold caches, as at a polling cadence), one executable path ≈ 2.6 µs, one argv
/// ≈ 11 µs, one parent ≈ 0.3 µs.
struct LiveProcessTable: ProcessTable, Sendable {
    /// Room for this many more PIDs than the kernel's estimate, for processes started in between.
    private static let pidHeadroom = 64
    /// `PROC_PIDPATHINFO_MAXSIZE`, which Swift doesn't import.
    private static let maxPathSize = 4 * Int(MAXPATHLEN)

    func processIDs() -> [pid_t] {
        var capacity = Int(proc_listallpids(nil, 0)) + Self.pidHeadroom
        // A full buffer may have cut the list short: grow and ask again.
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count >= 0 else { return [] }
            if count < capacity {
                pids.removeSubrange(Int(count)...)
                return pids
            }
            capacity *= 2
        }
        return []
    }

    func executablePath(of pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxPathSize) { buffer in
            let length = proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        }
    }

    /// `KERN_PROCARGS2` lays out argc (Int32), the executable path, NUL padding, then argc
    /// NUL-terminated arguments, then the environment (not read).
    func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        arguments.reserveCapacity(max(0, min(argc, 64)))
        while arguments.count < argc, index < size {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    func parentID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }
}
