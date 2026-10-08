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
/// aren't looked at again. A script runtime first seen running a script that isn't a session gets
/// no second look: npm's JavaScript build of Claude Code renames itself to a bare "claude" for
/// housekeeping commands too, so a second look could only mistake `claude mcp serve`, first seen
/// before it renamed itself, for a session. A new session isn't reported when a session of the
/// same tool is one of its ancestors (npm's codex.js and the binary it runs, a session's own
/// sub-sessions), nor within the cooldown of the tool's last report.
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
                let look = Self.look(at: pid, in: table)
                if let tool = look.tool {
                    next[pid] = .session(tool)
                    started.append((pid, tool))
                } else {
                    // Baseline processes are settled right away: re-reading hundreds of paths
                    // would only catch an exec racing start().
                    next[pid] = .other(settled: previous != nil || !hasBaseline || look.isFinal)
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
        look(at: pid, in: table).tool
    }

    /// The tool whose session `pid` is, and whether a non-session's answer is final: a script
    /// runtime whose argv names its script can't become a session without exec'ing, only rename
    /// itself.
    private static func look(at pid: pid_t, in table: some ProcessTable) -> (tool: Tool?, isFinal: Bool) {
        guard let path = table.executablePath(of: pid),
              CodingSessionMatcher.isCandidate(executablePath: path)
        else { return (nil, false) }
        let arguments = table.arguments(of: pid) ?? []
        let tool = CodingSessionMatcher.tool(executablePath: path, arguments: arguments)
        return (tool, tool == nil && CodingSessionMatcher.runsNamedScript(executablePath: path, arguments: arguments))
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
