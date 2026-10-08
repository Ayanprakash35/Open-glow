import Darwin
import Foundation
import Testing
@testable import OpenGlow

private typealias Tool = CodingSessionMonitor.Tool
private typealias Matcher = CodingSessionMatcher

// Paths and argv as they appear on a real Mac (`ps`, `proc_pidpath`, `KERN_PROCARGS2`).
private let desktopClaude = "/Users/me/Library/Application Support/Claude/claude-code/2.1.289/ee67e3f1ea60/claude.app/Contents/MacOS/claude"
private let desktopClaudeArguments = [
    desktopClaude, "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
    "--effort", "xhigh", "--model", "claude-opus-5-5", "--permission-prompt-tool", "stdio",
    "--resume=2059e46e-fdda-4c7f-8292-bb42ad37a071", "--setting-sources=user,project,local",
    "--add-dir", "/tmp", "--await-initialize",
]
private let nativeClaude = "/Users/me/.local/share/claude/versions/2.1.289"
private let brewClaude = "/opt/homebrew/Caskroom/claude-code/2.1.289/claude"
/// npm's package since 2.1.120: the platform binary, hardlinked or copied under this name.
private let npmClaude = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
/// npm's JavaScript build, up to 2.1.100.
private let npmClaudeScript = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
private let node = "/opt/homebrew/bin/node"
private let systemNode = "/usr/local/bin/node"
private let brewCodex = "/opt/homebrew/Caskroom/codex/0.46.0/codex-aarch64-apple-darwin"
private let npmCodexBinary = "/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex"
private let npmCodexScript = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
private let claudeApp = "/Applications/Claude.app/Contents/MacOS/Claude"
private let claudeHelper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
private let claudeRenderer = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
private let disclaimer = "/Applications/Claude.app/Contents/Helpers/disclaimer"
private let codexApp = "/Applications/Codex.app/Contents/MacOS/Codex"
private let codexAppCLI = "/Applications/Codex.app/Contents/Resources/codex"
private let zsh = "/bin/zsh"

private func match(_ path: String, _ arguments: [String]? = nil) -> Tool? {
    Matcher.tool(executablePath: path, arguments: arguments ?? [path])
}

@Suite("Coding sessions: matching")
struct CodingSessionMatchingTests {
    @Test func claudeCodeInstalls() {
        #expect(match(desktopClaude, desktopClaudeArguments) == .claudeCode)
        // The native installer's symlink resolves to a file named after the version.
        #expect(match(nativeClaude, ["claude"]) == .claudeCode)
        #expect(match(nativeClaude, ["claude", "--continue"]) == .claudeCode)
        #expect(match(brewClaude, ["claude", "-p", "summarize the diff"]) == .claudeCode)
    }

    /// npm's package runs its platform binary as `bin/claude.exe`, through npm's `claude` link.
    @Test func claudeCodeFromNpm() {
        #expect(match(npmClaude, ["claude"]) == .claudeCode)
        #expect(match(npmClaude, ["claude", "--resume"]) == .claudeCode)
        #expect(match(npmClaude, [npmClaude, "fix the tests"]) == .claudeCode)
        #expect(match("/Users/me/.nvm/versions/node/v22.12.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", ["claude"]) == .claudeCode)
        #expect(match("/Users/me/Library/pnpm/global/5/.pnpm/@anthropic-ai+claude-code@2.1.293/node_modules/@anthropic-ai/claude-code/bin/claude.exe", ["claude"]) == .claudeCode)
        // The platform package's own binary, run directly.
        #expect(match("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code-darwin-arm64/claude") == .claudeCode)
        // Housekeeping and stand-ins, as for every other install.
        #expect(match(npmClaude, ["claude", "mcp", "serve"]) == nil)
        #expect(match(npmClaude, ["claude", "--version"]) == nil)
        #expect(match(npmClaude, ["claude daemon", "--daemon-worker", "agents"]) == nil)
        #expect(match(npmClaude, ["ugrep", "-G", "-E", "TODO"]) == nil)
    }

    /// npm's JavaScript build sets its process title to "claude" as it starts a command, and
    /// Node writes that over its whole argv.
    @Test func renamedJavaScriptBuild() {
        #expect(match(node, ["claude", ""]) == .claudeCode)
        #expect(match(systemNode, ["claude", "", "", ""]) == .claudeCode)
        // Its helpers title themselves differently.
        #expect(match(node, ["claude daemon", ""]) == nil)
        #expect(match(node, ["claude daemon", "", "", ""]) == nil)
        #expect(match(node, ["claude bg-pty-host", "", ""]) == nil)
        // Only a bare "claude" over nothing but empty strings: not a node merely started as `claude`.
        #expect(match(node, ["claude"]) == nil)
        #expect(match(node, ["claude", "", "/Users/me/projects/site/server.js"]) == nil)
        #expect(match(node, ["claude", "/Users/me/projects/site/server.js"]) == nil)
        // Only node is renamed this way.
        #expect(match("/usr/bin/python3", ["claude", ""]) == nil)
        #expect(Matcher.isRenamedClaudeCode(["claude", ""]))
        #expect(!Matcher.isRenamedClaudeCode(["claude daemon", ""]))
    }

    @Test func claudeCodeThroughNode() {
        #expect(match(node, ["node", npmClaudeScript]) == .claudeCode)
        // npm's link, as the shell passes it through `#!/usr/bin/env node`.
        #expect(match(node, ["node", "/opt/homebrew/bin/claude", "--resume"]) == .claudeCode)
        #expect(match(systemNode, ["node", "/Users/me/.claude/local/node_modules/.bin/claude"]) == .claudeCode)
        #expect(match(node, ["node", "--no-warnings", "-r", "/tmp/hook.js", "--enable-source-maps", npmClaudeScript, "fix the tests"]) == .claudeCode)
        #expect(match(node, ["node", "--", npmClaudeScript]) == .claudeCode)
    }

    @Test func codexInstalls() {
        #expect(match(brewCodex, ["codex"]) == .codex)
        #expect(match(npmCodexBinary, [npmCodexBinary, "exec", "add a test"]) == .codex)
        #expect(match("/opt/homebrew/bin/codex", ["codex", "resume", "--last"]) == .codex)
        #expect(match("/usr/local/bin/codex-x86_64-apple-darwin") == .codex)
        #expect(match(node, ["node", npmCodexScript]) == .codex)
        #expect(match(node, ["node", "/opt/homebrew/bin/codex", "--model", "gpt-5"]) == .codex)
    }

    @Test func desktopAppsAreNotSessions() {
        for path in [claudeApp, claudeHelper, claudeRenderer, codexApp] {
            #expect(!Matcher.isCandidate(executablePath: path), "\(path)")
            #expect(match(path, [path, "--type=renderer", "--user-data-dir=/Users/me/Library/Application Support/Claude"]) == nil)
        }
        // The helper the Claude app launches sessions through carries the session's path in its
        // own arguments.
        #expect(match(disclaimer, [disclaimer, "--pgroup", "--"] + desktopClaudeArguments) == nil)
        // The Codex app's backend: one long-lived process for all its threads.
        #expect(match(codexAppCLI, [codexAppCLI, "app-server"]) == nil)
    }

    @Test func otherNodeProcessesAreNotSessions() {
        #expect(match(systemNode, ["node", "/Users/me/.npm/_npx/6583fba12287d067/node_modules/.bin/mcp-pdf-server", "--stdio"]) == nil)
        // `npm exec` rewrites its argv into its title, leaving empty strings behind.
        #expect(match(systemNode, ["npm exec @modelcontextprotocol/server-pdf --stdio", "", ""]) == nil)
        #expect(match(node, ["node", "/opt/homebrew/bin/npm", "exec", "@anthropic-ai/claude-code"]) == nil)
        #expect(match(node, ["node", "/Users/me/projects/site/server.js", "--port", "3000"]) == nil)
        #expect(match(node, ["node", "-e", "require('/opt/homebrew/bin/claude')"]) == nil)
        #expect(match(node, ["node"]) == nil)
        #expect(match(node, []) == nil)
        // A dependency inside Claude Code's own package isn't Claude Code.
        #expect(match(node, ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/node_modules/some-mcp/cli.js"]) == nil)
        #expect(match(node, ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-agent-sdk/cli.js"]) == nil)
    }

    @Test func foldersNamedLikeTheToolsAreNotSessions() {
        #expect(match(node, ["node", "/Users/me/claude/index.js"]) == nil)
        #expect(match(node, ["node", "/Users/me/codex/bin/serve.js"]) == nil)
        #expect(match("/Users/me/claude/.build/debug/app") == nil)
        #expect(match("/Users/me/claude/versions/notes") == nil)
        #expect(match("/Users/me/codex/target/release/server") == nil)
        #expect(match("/Users/me/bin/claude-helper") == nil)
        #expect(match("/Users/me/bin/codex-cli-wrapper") == nil)
        #expect(!Matcher.isCandidate(executablePath: "/Users/me/claude/.build/debug/app"))
        // `claude.exe` counts only inside npm's package.
        #expect(match("/Users/me/bin/claude.exe", ["claude"]) == nil)
        #expect(match("/Users/me/src/claude-code/bin/claude.exe", ["claude"]) == nil)
        #expect(match("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/claude.exe", ["claude"]) == nil)
        #expect(!Matcher.isCandidate(executablePath: "/Users/me/bin/claude.exe"))
    }

    @Test func housekeepingIsNotASession() {
        for arguments in [["claude", "--version"], ["claude", "-v"], ["claude", "--help"], ["claude", "mcp", "serve"],
                          ["claude", "mcp", "list"], ["claude", "doctor"], ["claude", "update"], ["claude", "--debug", "config", "list"]] {
            #expect(match(nativeClaude, arguments) == nil, "\(arguments)")
        }
        #expect(match(node, ["node", npmClaudeScript, "--version"]) == nil)
        for arguments in [["codex", "--version"], ["codex", "login"], ["codex", "mcp-server"], ["codex", "app-server"],
                          ["codex", "--codex-run-as-apply-patch", "*** Begin Patch"], ["codex", "completion", "zsh"]] {
            #expect(match(brewCodex, arguments) == nil, "\(arguments)")
        }
        #expect(match(node, ["node", npmCodexScript, "login"]) == nil)
        #expect(match(brewCodex, ["codex", "cloud"]) == nil)
        #expect(match(brewCodex, ["codex", "-c", "mcp_servers={}", "mcp-server"]) == nil)
    }

    /// Claude Code runs its own binary for helpers that aren't sessions (as of 2.1.289).
    @Test func claudeHelperModesAreNotSessions() {
        let spare = "/Users/me/.claude/bg/spare-1f2e"
        for arguments in [
            [nativeClaude, "--chrome-native-host", "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/"],
            [desktopClaude, "--claude-in-chrome-mcp"],
            [desktopClaude, "--computer-use-mcp"],
            [nativeClaude, "--bg-spare", spare],
            [nativeClaude, "--preload"],
            [nativeClaude, "--daemon-worker", "agents"],
            ["claude", "--dangerously-skip-permissions", "daemon", "start"],
            [nativeClaude, "--gh-standin", "53511", "/Users/me/.claude/gh/ca.pem", "--", "pr", "view", "12"],
            ["claude", "remote-control"],
            ["claude", "rc", "--name", "laptop"],
            ["claude", "agents"],
            ["claude", "plugin", "marketplace", "add", "anthropics/claude-plugins"],
        ] {
            #expect(match(nativeClaude, arguments) == nil, "\(arguments)")
        }
        // The PTY host names itself in argv[0], with a space; the session or spare it hosts follows `--`.
        let ptyHost = ["claude bg-pty-host", "--bg-pty-host", spare + ".pty.sock", "200", "50", "--", nativeClaude, "--bg-spare", spare]
        #expect(match(nativeClaude, ptyHost) == nil)
        // …while the session it hosts is one.
        #expect(match(nativeClaude, [nativeClaude, "--resume", "8d3c0a52-4b7e-4f0e-9a43-2f6c1e9d7b10"]) == .claudeCode)
    }

    /// Option values aren't mistaken for subcommands.
    @Test func optionValuesAreNotSubcommands() {
        #expect(match(nativeClaude, ["claude", "--add-dir", "project"]) == .claudeCode)
        #expect(match(nativeClaude, ["claude", "--model", "opus", "--add-dir", "sync", "refactor the parser"]) == .claudeCode)
        #expect(match(nativeClaude, ["claude", "--agent", "sandbox"]) == .claudeCode)
        #expect(match(brewCodex, ["codex", "--profile", "login"]) == .codex)
        #expect(match(brewCodex, ["codex", "-C", "/Users/me/src/cloud", "-c", "model=\"o3\"", "exec", "fix it"]) == .codex)
        #expect(match(brewCodex, ["codex", "-c", "model=\"o3\"", "login"]) == nil)
    }

    /// Claude Code's binary doubles as the grep of its shell; Codex's applies patches.
    @Test func binariesStandingInForOtherProgramsAreNotSessions() {
        #expect(match(desktopClaude, ["ugrep", "-G", "--ignore-files", "--hidden", "-I", "-E", "TODO"]) == nil)
        #expect(match(nativeClaude, ["rg", "--files"]) == nil)
        #expect(match(npmCodexBinary, ["apply_patch", "*** Begin Patch"]) == nil)
        // …while any spelling of the tool itself still counts.
        #expect(match(nativeClaude, ["/Users/me/.local/bin/claude"]) == .claudeCode)
        #expect(match(nativeClaude, [nativeClaude]) == .claudeCode)
        #expect(match(brewCodex, ["/opt/homebrew/bin/codex"]) == .codex)
        #expect(match(brewCodex, [brewCodex]) == .codex)
    }

    @Test func promptsAreNotMistakenForCommands() {
        #expect(match(nativeClaude, ["claude", "update the readme"]) == .claudeCode)
        #expect(match(nativeClaude, ["claude", "--model", "opus"]) == .claudeCode)
        // After `--`, everything is the prompt.
        #expect(match(nativeClaude, ["claude", "--", "--help"]) == .claudeCode)
        #expect(match(nativeClaude, ["claude", "--", "doctor"]) == .claudeCode)
        #expect(match(brewCodex, ["codex", "exec", "login flow is broken, fix it"]) == .codex)
    }

    /// Arguments of another user's process can't be read: a bare binary still counts.
    @Test func unreadableArguments() {
        #expect(Matcher.tool(executablePath: desktopClaude, arguments: []) == .claudeCode)
        #expect(Matcher.tool(executablePath: brewCodex, arguments: []) == .codex)
        #expect(Matcher.tool(executablePath: node, arguments: []) == nil)
    }
}

// MARK: - Tracking

/// An injected process table. Thread-safe so the monitor's polling task can read it too.
private final class FakeProcessTable: ProcessTable, @unchecked Sendable {
    struct Process {
        var path: String
        var arguments: [String]
        var parent: pid_t
    }

    private let lock = NSLock()
    private var processes: [pid_t: Process] = [:]
    private var pathReads = 0
    private var argumentReads = 0
    private var listings = 0

    init(_ processes: [pid_t: Process] = [:]) {
        self.processes = processes
    }

    func launch(_ pid: pid_t, _ path: String, _ arguments: [String]? = nil, parent: pid_t = 1) {
        lock.withLock { processes[pid] = Process(path: path, arguments: arguments ?? [path], parent: parent) }
    }

    func exit(_ pid: pid_t) {
        lock.withLock { processes[pid] = nil }
    }

    struct Reads: Equatable {
        var paths: Int
        var arguments: Int
    }

    /// Path and argument lookups since the last call.
    func takeReads() -> Reads {
        lock.withLock {
            defer { (pathReads, argumentReads) = (0, 0) }
            return Reads(paths: pathReads, arguments: argumentReads)
        }
    }

    var scanCount: Int { lock.withLock { listings } }

    func processIDs() -> [pid_t] {
        lock.withLock {
            listings += 1
            return Array(processes.keys)
        }
    }

    func executablePath(of pid: pid_t) -> String? {
        lock.withLock {
            pathReads += 1
            return processes[pid]?.path
        }
    }

    func arguments(of pid: pid_t) -> [String]? {
        lock.withLock {
            argumentReads += 1
            return processes[pid]?.arguments
        }
    }

    func parentID(of pid: pid_t) -> pid_t? {
        lock.withLock { processes[pid]?.parent }
    }
}

/// A desktop with Terminal, a shell, the Claude app and one Claude Code session in it.
private func desktop() -> FakeProcessTable {
    let table = FakeProcessTable()
    table.launch(100, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    table.launch(101, "/usr/bin/login", parent: 100)
    table.launch(102, zsh, ["-zsh"], parent: 101)
    table.launch(200, claudeApp)
    table.launch(201, claudeHelper, parent: 200)
    table.launch(210, disclaimer, [disclaimer, "--pgroup", "--"] + desktopClaudeArguments, parent: 200)
    table.launch(211, desktopClaude, desktopClaudeArguments, parent: 210)
    table.launch(212, systemNode, ["npm exec @modelcontextprotocol/server-pdf --stdio", "", ""], parent: 211)
    return table
}

@Suite("Coding sessions: tracking")
struct CodingSessionTrackingTests {
    @Test func sessionsRunningAtTheBaselineAreNotReported() {
        let table = desktop()
        table.launch(300, brewCodex, ["codex"], parent: 102)
        var tracker = CodingSessionTracker(cooldown: 5)
        #expect(tracker.scan(table, now: 0).isEmpty)
        #expect(tracker.runningSessions == [.claudeCode: 1, .codex: 1])
        #expect(tracker.scan(table, now: 2).isEmpty)
    }

    @Test func aNewSessionIsReportedOnce() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 5)
        _ = tracker.scan(table, now: 0)
        table.launch(220, disclaimer, [disclaimer, "--pgroup", "--"] + desktopClaudeArguments, parent: 200)
        table.launch(221, desktopClaude, desktopClaudeArguments, parent: 220)
        #expect(tracker.scan(table, now: 1.5) == [.claudeCode])
        #expect(tracker.scan(table, now: 3).isEmpty)
        #expect(tracker.scan(table, now: 30).isEmpty)
        #expect(tracker.runningSessions == [.claudeCode: 2])
    }

    @Test func aRestartedSessionIsReportedAgain() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 5)
        _ = tracker.scan(table, now: 0)
        table.launch(400, nativeClaude, ["claude"], parent: 102)
        #expect(tracker.scan(table, now: 1.5) == [.claudeCode])
        table.exit(400)
        #expect(tracker.scan(table, now: 10).isEmpty)
        table.launch(401, nativeClaude, ["claude", "--continue"], parent: 102)
        #expect(tracker.scan(table, now: 11.5) == [.claudeCode])
    }

    /// npm's codex.js runs the vendored binary as its child: one session, whether the child
    /// shows up in the same scan or the next.
    @Test func aSessionAndItsChildFireOnce() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        table.launch(500, node, ["node", "/opt/homebrew/bin/codex"], parent: 102)
        table.launch(501, npmCodexBinary, [npmCodexBinary], parent: 500)
        #expect(tracker.scan(table, now: 1.5) == [.codex])
        table.launch(502, npmCodexBinary, [npmCodexBinary, "--codex-run-as-apply-patch", "patch"], parent: 500)
        table.launch(503, npmCodexBinary, [npmCodexBinary], parent: 500)
        #expect(tracker.scan(table, now: 3).isEmpty)
    }

    /// A session's own sub-sessions (through a shell, a script…) are part of it — including those
    /// of a session that was already running at the baseline.
    @Test func descendantsOfASessionAreNotNewSessions() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        table.launch(600, zsh, ["/bin/zsh", "-c", "claude -p 'review'"], parent: 211)
        table.launch(601, "/bin/bash", ["bash", "run.sh"], parent: 600)
        table.launch(602, nativeClaude, ["claude", "-p", "review"], parent: 601)
        #expect(tracker.scan(table, now: 1.5).isEmpty)
        #expect(tracker.runningSessions == [.claudeCode: 2])
    }

    /// …but a session of the other tool started from one is new.
    @Test func otherToolStartedFromASessionIsNew() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        table.launch(700, zsh, ["/bin/zsh", "-c", "codex exec 'second opinion'"], parent: 211)
        table.launch(701, brewCodex, ["codex", "exec", "second opinion"], parent: 700)
        #expect(tracker.scan(table, now: 1.5) == [.codex])
    }

    @Test func startsWithinTheCooldownAreFolded() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 5)
        _ = tracker.scan(table, now: 0)
        table.launch(800, nativeClaude, ["claude"], parent: 102)
        table.launch(801, brewClaude, ["claude"], parent: 102)
        #expect(tracker.scan(table, now: 1.5) == [.claudeCode])
        table.launch(802, nativeClaude, ["claude"], parent: 102)
        #expect(tracker.scan(table, now: 3).isEmpty)
        // The cooldown is per tool.
        table.launch(803, brewCodex, ["codex"], parent: 102)
        #expect(tracker.scan(table, now: 4.5) == [.codex])
        table.launch(804, nativeClaude, ["claude"], parent: 102)
        #expect(tracker.scan(table, now: 6.5) == [.claudeCode])
    }

    @Test func bothToolsInOneScan() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 5)
        _ = tracker.scan(table, now: 0)
        table.launch(900, brewCodex, ["codex"], parent: 102)
        table.launch(901, nativeClaude, ["claude"], parent: 102)
        #expect(tracker.scan(table, now: 1.5) == [.claudeCode, .codex])
    }

    @Test func housekeepingRunsAreIgnored() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        table.launch(1000, desktopClaude, [desktopClaude, "--version"], parent: 200)
        table.launch(1001, codexAppCLI, [codexAppCLI, "app-server"], parent: 200)
        // Grep run by a shell left behind by a session (its parent gone, so no ancestor to tie
        // it to the session).
        table.launch(1002, desktopClaude, ["ugrep", "-G", "-E", "TODO"], parent: 1)
        #expect(tracker.scan(table, now: 1.5).isEmpty)
        #expect(tracker.runningSessions == [.claudeCode: 1])
    }

    /// A process caught before it exec'd into a session (a wrapper script) is classified once
    /// more on the next scan, and reported then.
    @Test func aWrapperThatExecsIntoASessionIsCaught() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        table.launch(1100, "/bin/bash", ["/bin/bash", "/Users/me/.claude/local/claude"], parent: 102)
        #expect(tracker.scan(table, now: 1.5).isEmpty)
        table.launch(1100, node, ["node", "/Users/me/.claude/local/node_modules/.bin/claude"], parent: 102)
        #expect(tracker.scan(table, now: 3) == [.claudeCode])
    }

    /// npm's JavaScript build is usually first seen already renamed to "claude"; either way, its
    /// session is reported once.
    @Test func theRenamedJavaScriptBuildIsReported() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        table.launch(1300, node, ["claude", ""], parent: 102)
        #expect(tracker.scan(table, now: 1.5) == [.claudeCode])
        // Seen before renaming itself, then renamed.
        table.launch(1301, node, ["node", "/opt/homebrew/bin/claude", "--continue"], parent: 102)
        #expect(tracker.scan(table, now: 3) == [.claudeCode])
        table.launch(1301, node, ["claude", "", ""], parent: 102)
        #expect(tracker.scan(table, now: 4.5).isEmpty)
        #expect(tracker.runningSessions == [.claudeCode: 3])
    }

    /// A housekeeping command of the JavaScript build seen before it renamed itself isn't taken
    /// for a session once it has.
    @Test func renamedHousekeepingSeenBeforeIsIgnored() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        _ = table.takeReads()
        table.launch(1400, node, ["node", npmClaudeScript, "mcp", "serve"], parent: 1)
        table.launch(1401, node, ["node", npmClaudeScript, "daemon"], parent: 1)
        #expect(tracker.scan(table, now: 1.5).isEmpty)
        #expect(table.takeReads() == .init(paths: 2, arguments: 2))
        table.launch(1400, node, ["claude", "", "", ""], parent: 1)
        table.launch(1401, node, ["claude daemon", "", ""], parent: 1)
        #expect(tracker.scan(table, now: 3).isEmpty)
        // Known for what they are after one look.
        #expect(table.takeReads() == .init(paths: 0, arguments: 0))
        #expect(tracker.runningSessions == [.claudeCode: 1])
    }

    /// Paths are read only for PIDs not seen before (and once more on the next scan), arguments
    /// only for likely executables.
    @Test func onlyNewProcessesAreLookedAt() {
        let table = desktop()
        var tracker = CodingSessionTracker(cooldown: 0)
        _ = tracker.scan(table, now: 0)
        // Arguments only for the session and the MCP server's node.
        #expect(table.takeReads() == .init(paths: 8, arguments: 2))

        _ = tracker.scan(table, now: 1.5)
        #expect(table.takeReads() == .init(paths: 0, arguments: 0))

        table.launch(1200, "/usr/bin/git", ["git", "status"], parent: 102)
        table.launch(1201, nativeClaude, ["claude"], parent: 102)
        _ = tracker.scan(table, now: 3)
        #expect(table.takeReads() == .init(paths: 2, arguments: 1))
        // Second look at the one that wasn't a session, then nothing.
        _ = tracker.scan(table, now: 4.5)
        #expect(table.takeReads() == .init(paths: 1, arguments: 0))
        _ = tracker.scan(table, now: 6)
        #expect(table.takeReads() == .init(paths: 0, arguments: 0))

        // A script runtime running a script that isn't a session gets one look; one whose argv
        // names no script (`npm exec`'s) gets two.
        table.launch(1202, node, ["node", "/Users/me/projects/site/server.js"], parent: 102)
        table.launch(1203, systemNode, ["npm exec @modelcontextprotocol/server-pdf --stdio", "", ""], parent: 102)
        _ = tracker.scan(table, now: 7.5)
        #expect(table.takeReads() == .init(paths: 2, arguments: 2))
        _ = tracker.scan(table, now: 9)
        #expect(table.takeReads() == .init(paths: 1, arguments: 1))
        _ = tracker.scan(table, now: 10.5)
        #expect(table.takeReads() == .init(paths: 0, arguments: 0))
    }
}

// MARK: - Monitor

/// Waits up to `timeout` for `condition`.
@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Coding sessions: monitor")
@MainActor
struct CodingSessionMonitorTests {
    @Test func reportsNewSessionsOnTheMainActor() async throws {
        let table = desktop()
        let monitor = CodingSessionMonitor(table: table, interval: 0.02, tolerance: 0, cooldown: 0)
        var reported: [Tool] = []
        monitor.onSessionStarted = { tool in
            MainActor.assertIsolated()
            reported.append(tool)
        }
        monitor.start()
        #expect(monitor.isStarted)
        try await waitUntil { table.scanCount >= 2 }
        #expect(reported.isEmpty)

        table.launch(300, brewCodex, ["codex"], parent: 102)
        try await waitUntil { !reported.isEmpty }
        #expect(reported == [.codex])

        monitor.stop()
        #expect(!monitor.isStarted)
        let scans = table.scanCount
        table.launch(301, nativeClaude, ["claude"], parent: 102)
        try await Task.sleep(for: .milliseconds(100))
        #expect(reported == [.codex])
        #expect(table.scanCount <= scans + 1)
    }

    /// A restart takes a new baseline: what started while stopped isn't reported.
    @Test func restartTakesANewBaseline() async throws {
        let table = desktop()
        let monitor = CodingSessionMonitor(table: table, interval: 0.02, tolerance: 0, cooldown: 0)
        var reported: [Tool] = []
        monitor.onSessionStarted = { reported.append($0) }
        monitor.start()
        try await waitUntil { table.scanCount >= 1 }
        monitor.stop()
        table.launch(300, brewCodex, ["codex"], parent: 102)
        let scans = table.scanCount
        monitor.start()
        try await waitUntil { table.scanCount >= scans + 3 }
        monitor.stop()
        #expect(reported.isEmpty)
    }
}

// MARK: - Palettes

@Suite("Coding sessions: palettes")
struct CodingSessionPaletteTests {
    @Test func claudeIsTerracotta() {
        let palette = Tool.claudeCode.palette
        #expect(abs(palette.primary.red - 0xD9 / 255.0) < 1e-9)
        #expect(abs(palette.primary.green - 0x77 / 255.0) < 1e-9)
        #expect(abs(palette.primary.blue - 0x57 / 255.0) < 1e-9)
        // Warm: red over green over blue in both colors.
        for color in [palette.primary, palette.secondary] {
            #expect(color.red > color.green && color.green > color.blue)
        }
    }

    @Test func codexIsCoolAndNotLikeAnyOtherPalette() {
        let palette = Tool.codex.palette
        for color in [palette.primary, palette.secondary] {
            #expect(color.blue > color.red && color.blue > color.green)
        }
        #expect(palette != Tool.claudeCode.palette)
        #expect(!PalettePresets.all.contains { $0.palette == palette || $0.palette == Tool.claudeCode.palette })
    }

    @Test func displayNames() {
        #expect(Tool.allCases.map(\.displayName) == ["Claude Code", "Codex"])
    }
}

// MARK: - Live

/// Reads the real process table; doesn't depend on any session running or starting.
@Suite("Coding sessions: live process table")
struct CodingSessionLiveTests {
    @Test func readsThisProcess() throws {
        let table = LiveProcessTable()
        let me = getpid()
        #expect(table.processIDs().contains(me))
        #expect(table.processIDs().contains(1))
        let path = try #require(table.executablePath(of: me))
        #expect(path.hasPrefix("/"))
        #expect(table.parentID(of: me) == getppid())
        let arguments = try #require(table.arguments(of: me))
        #expect(arguments == CommandLine.arguments)
        // launchd's arguments belong to root.
        #expect(table.arguments(of: 1) == nil)
        #expect(table.executablePath(of: 999_999) == nil)
    }

    /// A real process that looks like a session — a copy of `sleep` named `claude` or `codex` —
    /// is spotted by a real scan; the same binary standing in for grep isn't.
    @Test func spotsSessionsStarting() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenGlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = try makeStandIn(named: "claude", in: directory)
        let codex = try makeStandIn(named: "codex", in: directory)

        let table = LiveProcessTable()
        var tracker = CodingSessionTracker(cooldown: 0)
        #expect(tracker.scan(table, now: 0).isEmpty)

        var pids: [pid_t] = []
        defer { for pid in pids { kill(pid, SIGKILL) } }
        let session = try launchOrphan(claude, ["claude", "20"])
        let grep = try launchOrphan(claude, ["ugrep", "20"])
        let codexSession = try launchOrphan(codex, [codex, "20"])
        pids = [session, grep, codexSession]

        #expect(CodingSessionTracker.classify(session, in: table) == .claudeCode)
        #expect(CodingSessionTracker.classify(grep, in: table) == nil)
        #expect(CodingSessionTracker.classify(codexSession, in: table) == .codex)
        #expect(tracker.scan(table, now: 1) == [.claudeCode, .codex])
        #expect(tracker.scan(table, now: 2).isEmpty)
    }

    /// npm's package layout: the binary at `…/@anthropic-ai/claude-code/bin/claude.exe`, copied or
    /// hardlinked from the platform package, run through npm's `claude` symlink.
    @Test(arguments: [false, true])
    func spotsTheNpmPackage(hardlinked: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenGlowTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let modules = directory.appending(path: "lib/node_modules/@anthropic-ai")
        let binFolder = modules.appending(path: "claude-code/bin")
        try FileManager.default.createDirectory(at: binFolder, withIntermediateDirectories: true)
        let binary = binFolder.appending(path: "claude.exe").path
        if hardlinked {
            let platform = modules.appending(path: "claude-code-darwin-arm64")
            try FileManager.default.createDirectory(at: platform, withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: try makeStandIn(named: "claude", in: platform), toPath: binary)
        } else {
            _ = try makeStandIn(named: "claude.exe", in: binFolder)
        }
        let link = directory.appending(path: "bin/claude").path
        try FileManager.default.createDirectory(at: directory.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe")

        let table = LiveProcessTable()
        let session = try launchOrphan(link, ["claude", "20"])
        defer { kill(session, SIGKILL) }
        let path = try #require(table.executablePath(of: session))
        // A copy can only be reported under its own name; macOS may report either name of a hardlink.
        if !hardlinked { #expect(path.hasSuffix("/claude-code/bin/claude.exe"), "\(path)") }
        #expect(CodingSessionTracker.classify(session, in: table) == .claudeCode, "\(path)")
    }

    /// npm's JavaScript build renames itself "claude" (its daemon "claude daemon"), and Node writes
    /// the title over the whole argv. Needs Node; a stand-in script does the renaming.
    @Test(.enabled(if: installedNode != nil))
    func spotsTheRenamedJavaScriptBuild() async throws {
        let node = try #require(installedNode)
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenGlowTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appending(path: "lib/node_modules/@anthropic-ai/claude-code")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let script = package.appending(path: "cli.js").path
        try #"process.title = process.argv[2] === "daemon" ? "claude daemon" : "claude"; setTimeout(() => {}, 20000);"#
            .write(toFile: script, atomically: true, encoding: .utf8)

        let table = LiveProcessTable()
        let session = try launchOrphan(node, ["node", script, "--continue"])
        let daemon = try launchOrphan(node, ["node", script, "daemon"])
        defer { for pid in [session, daemon] { kill(pid, SIGKILL) } }
        try await waitUntil {
            table.arguments(of: session)?.first == "claude" && table.arguments(of: daemon)?.first == "claude daemon"
        }
        #expect(table.arguments(of: session) == ["claude", "", ""])
        #expect(CodingSessionTracker.classify(session, in: table) == .claudeCode)
        #expect(CodingSessionTracker.classify(daemon, in: table) == nil)
    }

    @Test func scansQuickly() {
        let table = LiveProcessTable()
        let clock = ContinuousClock()
        var tracker = CodingSessionTracker()
        let baseline = clock.measure { _ = tracker.scan(table, now: 0) }
        // Best of several: other suites run in parallel and can preempt any single one.
        let steady = (0..<20).map { index in
            clock.measure { _ = tracker.scan(table, now: Double(index + 1)) }
        }.min() ?? .zero
        print("coding sessions: \(table.processIDs().count) processes, baseline scan \(baseline), steady scan \(steady), running \(tracker.runningSessions)")
        #expect(baseline < .milliseconds(100), "baseline \(baseline)")
        #expect(steady < .milliseconds(5), "steady \(steady)")
    }
}

/// Node, where the usual installs put it, for the tests that need a real one.
private let installedNode = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first {
    FileManager.default.isExecutableFile(atPath: $0)
}

/// A stand-in for a tool's binary: a copy of `sleep` named `name`, re-signed ad hoc so it may run
/// from outside the system volume.
private func makeStandIn(named name: String, in directory: URL) throws -> String {
    let path = directory.appending(path: name).path
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
    let codesign = Process()
    codesign.executableURL = URL(filePath: "/usr/bin/codesign")
    codesign.arguments = ["--force", "--sign", "-", path]
    codesign.standardError = FileHandle.nullDevice
    try codesign.run()
    codesign.waitUntilExit()
    try #require(codesign.terminationStatus == 0)
    return path
}

/// Starts `path` with `arguments` (argv[0] first) and lets launchd adopt it, as a session started
/// from Terminal or the Claude app has no session among its ancestors (these tests may run inside
/// one). Returns its PID.
private func launchOrphan(_ path: String, _ arguments: [String]) throws -> pid_t {
    let shell = Process()
    shell.executableURL = URL(filePath: "/bin/bash")
    shell.arguments = ["-c", #"argv0="$1"; shift; (exec -a "$argv0" "$@" </dev/null >/dev/null 2>&1) & echo $!"#, "bash"]
        + [arguments[0], path] + arguments.dropFirst()
    let output = Pipe()
    shell.standardOutput = output
    try shell.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    shell.waitUntilExit()
    return try #require(pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
}
