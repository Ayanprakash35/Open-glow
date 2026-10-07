import Darwin
import Foundation

/// Session-start debouncing.
enum CodingSessionTrackerConfig {
    /// Seconds after a tool's session start during which further starts of the same tool are
    /// folded into it (several sessions opened at once, an app resuming its sessions). Sane
    /// range: 2–30.
    static let cooldown: TimeInterval = 5
    /// Most parents walked up from a new session looking for a session of the same tool that
    /// started it (session → shell → script → session). Sane range: 4–32.
    static let maxAncestorDepth = 16
}

/// Turns successive scans of the process table into session starts.
///
/// The first scan is the baseline: sessions already running then are never reported. After that,
/// a process is classified when its PID first appears and once more on the next scan, in case it
/// was caught just before exec'ing into a session (a wrapper script, `env node`); PIDs seen twice
/// aren't looked at again. A new session isn't reported when a session of the same tool is one of
/// its ancestors (npm's codex.js and the binary it runs, a session's own sub-sessions), nor
/// within the cooldown of the tool's last report.
///
/// Not thread-safe; owned by one polling task.
struct CodingSessionTracker {
    typealias Tool = CodingSessionMonitor.Tool

    private enum Entry {
        case session(Tool)
        /// Not a session; `settled` once it has been classified twice.
        case other(settled: Bool)
    }

    private let cooldown: TimeInterval
    private var entries: [pid_t: Entry] = [:]
    private var lastReport: [Tool: TimeInterval] = [:]
    private var hasBaseline = false

    init(cooldown: TimeInterval = CodingSessionTrackerConfig.cooldown) {
        self.cooldown = cooldown
    }

    /// Running sessions per tool, as of the last scan (baseline ones included).
    var runningSessions: [Tool: Int] {
        entries.values.reduce(into: [:]) { counts, entry in
            if case .session(let tool) = entry { counts[tool, default: 0] += 1 }
        }
    }

    /// Scans `table` and returns the tools with a session that started since the previous scan,
    /// each at most once, in `Tool.allCases` order. `now` is any monotonic clock in seconds.
    mutating func scan(_ table: some ProcessTable, now: TimeInterval) -> [Tool] {
        let pids = table.processIDs()
        var next: [pid_t: Entry] = [:]
        next.reserveCapacity(pids.count)
        var started: [(pid: pid_t, tool: Tool)] = []
        for pid in pids {
            switch entries[pid] {
            case .session(let tool)?:
                next[pid] = .session(tool)
            case .other(settled: true)?:
                next[pid] = .other(settled: true)
            case let previous:
                if let tool = Self.classify(pid, in: table) {
                    next[pid] = .session(tool)
                    started.append((pid, tool))
                } else {
                    // Baseline processes are settled right away: re-reading hundreds of paths
                    // would only catch an exec racing start().
                    next[pid] = .other(settled: previous != nil || !hasBaseline)
                }
            }
        }
        entries = next
        guard hasBaseline else {
            hasBaseline = true
            return []
        }

        var reported: Set<Tool> = []
        for (pid, tool) in started where !reported.contains(tool) {
            guard !hasAncestorSession(of: pid, tool: tool, in: table) else { continue }
            if let last = lastReport[tool], now - last < cooldown { continue }
            lastReport[tool] = now
            reported.insert(tool)
        }
        return Tool.allCases.filter(reported.contains)
    }

    /// The tool whose session `pid` is; reads its arguments only for likely executables.
    static func classify(_ pid: pid_t, in table: some ProcessTable) -> Tool? {
        guard let path = table.executablePath(of: pid),
              CodingSessionMatcher.isCandidate(executablePath: path)
        else { return nil }
        return CodingSessionMatcher.tool(executablePath: path, arguments: table.arguments(of: pid) ?? [])
    }

    private func hasAncestorSession(of pid: pid_t, tool: Tool, in table: some ProcessTable) -> Bool {
        var current = pid
        for _ in 0..<CodingSessionTrackerConfig.maxAncestorDepth {
            // launchd (1) and the kernel (0) end every chain.
            guard let parent = table.parentID(of: current), parent > 1, parent != current else { return false }
            if case .session(let parentTool)? = entries[parent], parentTool == tool { return true }
            current = parent
        }
        return false
    }
}
