import Foundation
import Testing
@testable import OpenGlow

@Suite("Coding activity")
struct CodingActivityTests {
    // MARK: - Claude Code transcripts

    private func claude(_ entries: [String]) -> TurnState? {
        CodingActivityParser.claudeCodeState(newestFirst: entries.reversed().map { Substring($0) })
    }

    private let prompt = #"{"type":"user","message":{"role":"user","content":"fix the bug"}}"#
    private let toolUse = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
    private let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
    private let reply = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#
    private let stopSummary = #"{"type":"system","subtype":"stop_hook_summary"}"#
    private let bookkeeping = [
        #"{"type":"attachment"}"#, #"{"type":"last-prompt"}"#, #"{"type":"custom-title"}"#,
        #"{"type":"ai-title"}"#, #"{"type":"cost-state"}"#, #"{"type":"queue-operation"}"#,
    ]

    @Test func aPromptStartsATurnAndAFinishedReplyEndsIt() {
        #expect(claude([reply, stopSummary, prompt]) == .working, "just sent")
        #expect(claude([prompt, toolUse]) == .working)
        #expect(claude([prompt, toolUse, toolResult]) == .working, "between tool calls")
        #expect(claude([prompt, toolUse, toolResult, reply]) == .idle)
        #expect(claude([prompt, toolUse, toolResult, reply, stopSummary]) == .idle)
    }

    @Test func bookkeepingAndSubagentEntriesDecideNothing() {
        #expect(claude([prompt] + bookkeeping) == .working)
        #expect(claude([prompt, reply] + bookkeeping) == .idle)
        let subagentReply = #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn"}}"#
        #expect(claude([prompt, toolUse, subagentReply]) == .working, "a subagent finishing doesn't end the turn")
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>"}}"#
        #expect(claude([prompt, reply, meta]) == .idle)
        #expect(claude(bookkeeping) == nil, "nothing to go on")
        #expect(claude(["not json", "{"]) == nil)
    }

    @Test func interruptionsAndLocalCommandsAreIdle() {
        let interrupted = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        #expect(claude([prompt, toolUse, interrupted]) == .idle)
        let command = #"{"type":"user","message":{"content":"<local-command-stdout>Set model</local-command-stdout>"}}"#
        #expect(claude([reply, command]) == .idle)
        #expect(claude([reply, #"{"type":"system","subtype":"local_command"}"#]) == .idle)
    }

    // MARK: - Codex rollouts

    private func codex(_ events: [String]) -> TurnState? {
        let lines = events.map { #"{"type":"event_msg","payload":{"type":"\#($0)"}}"# }
        let filler = #"{"type":"response_item","payload":{"type":"message"}}"#
        return CodingActivityParser.codexState(newestFirst: (lines + [filler]).reversed().map { Substring($0) })
    }

    @Test func codexTurnsRunFromTaskStartedToTaskComplete() {
        #expect(codex(["task_started"]) == .working)
        #expect(codex(["task_started", "item_completed", "token_count"]) == .working)
        #expect(codex(["task_started", "task_complete"]) == .idle)
        #expect(codex(["task_started", "turn_aborted"]) == .idle)
        #expect(codex(["task_started", "task_complete", "task_started"]) == .working)
        #expect(codex(["token_count"]) == nil)
    }

    @Test func aTailDropsItsCutFirstLine() {
        let data = Data("half a line}\n{\"a\":1}\n{\"b\":2}\n".utf8)
        #expect(CodingActivityParser.lines(ofTail: data, isWholeFile: false) == [#"{"b":2}"#, #"{"a":1}"#])
        #expect(CodingActivityParser.lines(ofTail: data, isWholeFile: true).count == 3)
    }

    // MARK: - Scanner

    @Test func scannerCountsWorkingSessionsAndSkipsStaleOnes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let fs = FakeFileSystem()
        let home = URL(fileURLWithPath: "/home")
        let project = home.appendingPathComponent(".claude/projects/-p")
        fs.add(project.appendingPathComponent("a.jsonl"), [prompt, toolUse].joined(separator: "\n"), modified: now)
        fs.add(project.appendingPathComponent("b.jsonl"), [prompt, reply].joined(separator: "\n"), modified: now)
        fs.add(project.appendingPathComponent("c.jsonl"), prompt, modified: now - CodingActivityConfig.staleSeconds - 1)
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        fs.add(day.appendingPathComponent("rollout-1.jsonl"), #"{"type":"event_msg","payload":{"type":"task_started"}}"#, modified: now)

        var scanner = CodingActivityScanner(fileSystem: fs, home: home, calendar: calendar)
        #expect(scanner.scan(now: now) == [.claudeCode: 1, .codex: 1])

        // Finishing a turn shows on the next scan; an unchanged log isn't read again.
        fs.add(project.appendingPathComponent("a.jsonl"), [prompt, toolUse, reply].joined(separator: "\n"), modified: now + 1)
        let reads = fs.tailReads
        #expect(scanner.scan(now: now + 2) == [.codex: 1])
        #expect(fs.tailReads == reads + 1, "only the changed log is read")
    }

    /// Live check against this Mac's logs: `OPENGLOW_ACTIVITY_PROBE=1`.
    @Test func probe() {
        guard ProcessInfo.processInfo.environment["OPENGLOW_ACTIVITY_PROBE"] != nil else { return }
        var scanner = CodingActivityScanner()
        let start = Date()
        let working = scanner.scan(now: Date())
        print("Working sessions: \(working) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let again = Date()
        _ = scanner.scan(now: Date())
        print("Repeat scan: \(Int(Date().timeIntervalSince(again) * 1_000_000)) µs")
    }
}

private final class FakeFileSystem: ActivityFileSystem, @unchecked Sendable {
    private var entries: [URL: (data: Data, modified: Date)] = [:]
    private(set) var tailReads = 0

    func add(_ url: URL, _ text: String, modified: Date) {
        entries[url.standardizedFileURL] = (Data(text.utf8), modified)
    }

    func files(in directory: URL) -> [(url: URL, modified: Date, size: Int)] {
        let dir = directory.standardizedFileURL.path
        return entries.compactMap { url, entry in
            url.deletingLastPathComponent().path == dir ? (url, entry.modified, entry.data.count) : nil
        }
    }

    func subdirectories(of directory: URL) -> [URL] {
        let dir = directory.standardizedFileURL.path + "/"
        var result: Set<String> = []
        for url in entries.keys where url.path.hasPrefix(dir) {
            if let first = url.path.dropFirst(dir.count).split(separator: "/").first, url.path.dropFirst(dir.count).contains("/") {
                result.insert(dir + first)
            }
        }
        return result.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func tail(of url: URL, bytes: Int) -> Data? {
        tailReads += 1
        return entries[url.standardizedFileURL].map { $0.data.suffix(bytes) }
    }
}
