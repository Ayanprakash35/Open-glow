import Foundation

/// How session logs are read for coding activity.
enum CodingActivityConfig {
    /// A log not written for this long counts as idle, whatever its last entry says: a turn that
    /// ended without a marker (a crash, a killed process). Seconds; long enough for one slow tool
    /// call (a long build) inside a turn. Sane range: 300–1800.
    static let staleSeconds: TimeInterval = 900
    /// Bytes read from the end of a log to find its latest entries. A single entry can be large
    /// (a tool's output), so this is generous. Sane range: 16–512 KB.
    static let tailBytes = 128 * 1024
    /// Seconds between full walks of the Codex log folders, which only finds older sessions picked
    /// up again; new ones are found at once in today's folder. Sane range: 5–60.
    static let codexDiscoverySeconds: TimeInterval = 15
}

/// Whether a coding tool is in the middle of answering a prompt, by its own session log.
enum TurnState: Equatable, Sendable {
    case working
    case idle
}

/// Reads a coding tool's turn state from the newest entries of the session log it keeps anyway.
/// Only the kind of each entry is looked at (a prompt, a tool result, a finished reply, an
/// interruption) — never what it says.
enum CodingActivityParser {
    /// Claude Code's transcript (`~/.claude/projects/<project>/<session>.jsonl`, one JSON entry a
    /// line). A turn starts with the prompt and runs through tool calls and their results; it ends
    /// with a finished reply (`stop_reason` "end_turn"), the stop-hook summary written after it, or
    /// an "[Request interrupted by user…]" line. Bookkeeping entries (titles, attachments, costs)
    /// and subagents' entries say nothing either way. `lines` runs newest first; nil when nothing
    /// in them decides.
    static func claudeCodeState(newestFirst lines: [Substring]) -> TurnState? {
        for line in lines {
            guard let entry = object(line) else { continue }
            if entry["isSidechain"] as? Bool == true { continue }
            switch entry["type"] as? String {
            case "assistant":
                let message = entry["message"] as? [String: Any]
                switch message?["stop_reason"] as? String {
                case "end_turn", "stop_sequence": return .idle
                default: return .working
                }
            case "user":
                if entry["isMeta"] as? Bool == true { continue }
                let text = userText(entry["message"] as? [String: Any])
                if text.contains("[Request interrupted by user") { return .idle }
                // A local command (/config, /model…) prints its output without a model turn.
                if text.contains("<local-command-stdout>") || text.contains("<local-command-stderr>") { return .idle }
                return .working
            case "system":
                switch entry["subtype"] as? String {
                case "stop_hook_summary", "local_command": return .idle
                default: continue
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Codex's rollout log (`~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl`): each turn is an
    /// event "task_started" … "task_complete" (or "turn_aborted" when interrupted). `lines` runs
    /// newest first; nil when nothing in them decides.
    static func codexState(newestFirst lines: [Substring]) -> TurnState? {
        for line in lines {
            // Cheap pre-check: most lines are model output, not turn events.
            guard line.contains("\"event_msg\""), let entry = object(line),
                  entry["type"] as? String == "event_msg",
                  let payload = entry["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "task_started": return .working
            case "task_complete", "turn_aborted", "shutdown_complete": return .idle
            default: continue
            }
        }
        return nil
    }

    /// The complete lines of `tail` (the end of a log), newest first. The first line is dropped
    /// unless `isWholeFile`, since the read most likely started partway into it.
    static func lines(ofTail tail: Data, isWholeFile: Bool) -> [Substring] {
        let text = String(decoding: tail, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        return lines.reversed()
    }

    private static func object(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A user entry's text: its content when that's a string, else its text parts joined.
    private static func userText(_ message: [String: Any]?) -> String {
        if let text = message?["content"] as? String { return text }
        let parts = message?["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
}

/// The few file operations the scanner needs — a protocol so tests can use a made-up tree.
protocol ActivityFileSystem {
    /// Regular files directly in `directory`, with when each was last written and its size.
    func files(in directory: URL) -> [(url: URL, modified: Date, size: Int)]
    /// Folders directly in `directory`.
    func subdirectories(of directory: URL) -> [URL]
    /// The last `bytes` bytes of `url` (all of it if shorter).
    func tail(of url: URL, bytes: Int) -> Data?
}

struct LocalActivityFileSystem: ActivityFileSystem {
    func files(in directory: URL) -> [(url: URL, modified: Date, size: Int)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return (url, modified, values.fileSize ?? 0)
        }
    }

    func subdirectories(of directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return try? handle.readToEnd()
    }
}

/// Counts the Claude Code and Codex sessions that are working on a prompt right now, from their
/// session logs. Each scan only lists folders and checks modification dates; a log is read (its
/// last `tailBytes`) only when it changed since the last scan. Nothing is written or sent.
struct CodingActivityScanner {
    typealias Tool = CodingSessionMonitor.Tool

    private let fileSystem: any ActivityFileSystem
    private let claudeProjects: URL
    private let codexSessions: URL
    private let calendar: Calendar
    /// Per log: the size and date it was read at, and what it said.
    private var known: [URL: (modified: Date, size: Int, state: TurnState?)] = [:]
    /// Codex logs written recently, found by the last full walk.
    private var codexCandidates: Set<URL> = []
    private var lastCodexDiscovery: Date?

    init(
        fileSystem: any ActivityFileSystem = LocalActivityFileSystem(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        calendar: Calendar = .current
    ) {
        self.fileSystem = fileSystem
        claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        codexSessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.calendar = calendar
    }

    /// How many sessions of each tool are mid-turn at `now`.
    mutating func scan(now: Date) -> [Tool: Int] {
        var working: [Tool: Int] = [:]
        var seen: Set<URL> = []

        let claudeLogs = fileSystem.subdirectories(of: claudeProjects).flatMap { fileSystem.files(in: $0) }
        for log in claudeLogs where log.url.pathExtension == "jsonl" {
            seen.insert(log.url)
            if state(of: log, now: now, parse: CodingActivityParser.claudeCodeState) == .working {
                working[.claudeCode, default: 0] += 1
            }
        }

        for log in codexLogs(now: now) {
            seen.insert(log.url)
            if state(of: log, now: now, parse: CodingActivityParser.codexState) == .working {
                working[.codex, default: 0] += 1
            }
        }

        known = known.filter { seen.contains($0.key) }
        return working
    }

    /// One log's state: idle once it's stale, otherwise what its newest entries say (re-read only
    /// when it changed).
    private mutating func state(
        of log: (url: URL, modified: Date, size: Int), now: Date,
        parse: ([Substring]) -> TurnState?
    ) -> TurnState? {
        guard now.timeIntervalSince(log.modified) < CodingActivityConfig.staleSeconds else { return nil }
        if let cached = known[log.url], cached.modified == log.modified, cached.size == log.size {
            return cached.state
        }
        var state: TurnState?
        if let tail = fileSystem.tail(of: log.url, bytes: CodingActivityConfig.tailBytes) {
            let lines = CodingActivityParser.lines(ofTail: tail, isWholeFile: log.size <= CodingActivityConfig.tailBytes)
            state = parse(lines)
        }
        known[log.url] = (log.modified, log.size, state)
        return state
    }

    /// Codex logs worth checking: today's and yesterday's folders every time (where new sessions
    /// appear), plus recently written ones anywhere from the last full walk (older sessions
    /// picked up again).
    private mutating func codexLogs(now: Date) -> [(url: URL, modified: Date, size: Int)] {
        if lastCodexDiscovery.map({ now.timeIntervalSince($0) >= CodingActivityConfig.codexDiscoverySeconds }) ?? true {
            lastCodexDiscovery = now
            codexCandidates = []
            for year in fileSystem.subdirectories(of: codexSessions) {
                for month in fileSystem.subdirectories(of: year) {
                    for day in fileSystem.subdirectories(of: month) {
                        for log in fileSystem.files(in: day)
                        where log.url.pathExtension == "jsonl" && now.timeIntervalSince(log.modified) < CodingActivityConfig.staleSeconds {
                            codexCandidates.insert(log.url)
                        }
                    }
                }
            }
        }
        var logs: [URL: (url: URL, modified: Date, size: Int)] = [:]
        for daysAgo in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            for log in fileSystem.files(in: dayFolder(for: date)) where log.url.pathExtension == "jsonl" {
                logs[log.url] = log
            }
        }
        for url in codexCandidates where logs[url] == nil {
            if let log = fileSystem.files(in: url.deletingLastPathComponent()).first(where: { $0.url == url }) {
                logs[url] = log
            }
        }
        return Array(logs.values)
    }

    private func dayFolder(for date: Date) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return codexSessions
            .appendingPathComponent(String(format: "%04d", parts.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day ?? 0), isDirectory: true)
    }
}
