import Foundation

/// Decides from a process's executable path and arguments whether it is a coding-agent session.
/// Pure: nothing here touches the process table.
///
/// What a session looks like on macOS:
/// - Claude Code: an executable named `claude` — the Claude desktop app's bundled copy
///   (…/Claude/claude-code/<version>/<hash>/claude.app/Contents/MacOS/claude), Homebrew's, or
///   npm's native package. The native installer's `~/.local/bin/claude` is a symlink to
///   `~/.local/share/claude/versions/<version>`, and macOS reports the resolved file, so the
///   executable is then named after the version. npm's JavaScript build runs as
///   `node …/@anthropic-ai/claude-code/cli.js` (or `node …/bin/claude` through npm's link).
/// - Codex: an executable named `codex` (npm's vendored binary, Homebrew's formula, the Codex
///   app's bundled CLI) or `codex-<arch>-apple-darwin` (release archives and Homebrew's cask),
///   or npm's launcher `node …/@openai/codex/bin/codex.js`, which runs the vendored binary as
///   its child.
///
/// Not sessions: the Claude desktop app itself ("Claude", "Claude Helper…") and the Codex app
/// ("Codex") — names are compared case-sensitively — MCP servers and other node scripts, the
/// tools' own housekeeping commands (`--version`, `claude mcp serve`, `codex app-server`,
/// `codex login`…) and helper modes (Claude Code's Chrome native host, its background-agent
/// daemon, PTY hosts and pre-warmed spares), listed below, and a tool's binary standing in for
/// another program: Claude Code runs its own binary as `ugrep`/`rg` for its shell's grep, as
/// `claude bg-pty-host` and as a `gh` shim, Codex runs its own as `apply_patch`; argv[0] then
/// names that program. (The helper modes were read from Claude Code 2.1.289's entry point.)
enum CodingSessionMatcher {
    typealias Tool = CodingSessionMonitor.Tool

    /// First positional arguments that run housekeeping rather than a session. `daemon` and the
    /// Remote Control server (`remote-control` and its aliases) only wait for work: the sessions
    /// they start are processes of their own.
    private static let claudeCommands: Set<String> = [
        "mcp", "config", "doctor", "update", "upgrade", "install", "uninstall", "setup-token",
        "migrate-installer", "plugin", "plugins", "auth", "login", "logout", "agents", "daemon",
        "remote-control", "rc", "remote", "bridge", "sync", "gateway", "project", "sandbox",
        "import", "import-conversations", "auto-mode",
    ]
    /// `app-server` is the long-lived backend of the Codex app and editor extensions: their
    /// threads don't start processes of their own, so they can't be seen from here.
    /// `cloud` browses and submits Codex cloud tasks, which run elsewhere.
    private static let codexCommands: Set<String> = [
        "app-server", "mcp-server", "mcp", "login", "logout", "completion", "debug", "sandbox",
        "apply", "a", "help", "features", "responses-api-proxy", "stdio-to-uds", "generate-ts", "cloud",
    ]
    /// Flags (anywhere before `--`) that make the run print something and exit, or run a helper
    /// instead of a session. Codex re-runs its own binary with `--codex-run-as-apply-patch` to
    /// apply edits.
    private static let claudeHelperFlags: Set<String> = [
        "-v", "--version", "-h", "--help", "--update", "--upgrade", "--chrome-native-host",
        "--claude-in-chrome-mcp", "--computer-use-mcp", "--eval-mock-server", "--gh-standin",
        "--bg-spare", "--bg-pty-host", "--preload", "--daemon-worker",
    ]
    private static let codexHelperFlags: Set<String> = ["-V", "--version", "-h", "--help", "--codex-run-as-apply-patch"]

    /// Options that take their value as the next argument, so a value (a folder named `project`,
    /// a profile named `login`) isn't taken for a subcommand. Only those likely to carry a plain
    /// word; `--option=value` is one argument anyway.
    private static let claudeOptionsWithValue: Set<String> = [
        "--add-dir", "--plugin-dir", "--model", "--fallback-model", "--agent", "--permission-mode",
        "--settings", "--setting-sources", "--mcp-config", "-r", "--resume", "--session-id", "--effort",
    ]
    private static let codexOptionsWithValue: Set<String> = [
        "-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a",
        "--ask-for-approval", "-C", "--cd", "--add-dir", "-i", "--image", "--enable", "--disable",
        "--local-provider",
    ]

    /// Script runtimes whose script argument is checked.
    private static let scriptRuntimes: Set<String> = ["node"]
    /// Node options that take their value as the next argument, so it isn't taken for the script.
    private static let nodeOptionsWithValue: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
        "--inspect-port", "--title", "--env-file", "--input-type",
    ]
    /// Node options that run inline code instead of a script.
    private static let nodeInlineCodeOptions: Set<String> = ["-e", "--eval", "-p", "--print"]

    /// Whether the process at `executablePath` might be a session, i.e. whether its arguments
    /// are worth reading. False for nearly every process, so their arguments are never read.
    static func isCandidate(executablePath: String) -> Bool {
        binaryTool(executablePath) != nil || isScriptRuntime(executablePath)
    }

    /// The tool whose session the process is, or nil. `arguments` is the full argv, including
    /// argv[0]; pass an empty array when it can't be read (a bare binary then counts as a
    /// session, a script runtime doesn't).
    static func tool(executablePath: String, arguments: [String]) -> Tool? {
        if let tool = binaryTool(executablePath) {
            guard runsAsItself(tool, executablePath: executablePath, argv0: arguments.first) else { return nil }
            return isSession(tool, arguments: arguments.dropFirst()) ? tool : nil
        }
        guard isScriptRuntime(executablePath),
              let scriptIndex = nodeScriptIndex(in: arguments),
              let tool = scriptTool(arguments[scriptIndex])
        else { return nil }
        return isSession(tool, arguments: arguments[(scriptIndex + 1)...]) ? tool : nil
    }

    // MARK: - Helpers

    /// The tool an executable belongs to, by its file name (and, for the native installer, its
    /// folder).
    static func binaryTool(_ path: String) -> Tool? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = components.last else { return nil }
        if name == "claude" { return .claudeCode }
        // …/claude/versions/2.1.0, the native installer's layout.
        if components.count >= 3,
           components[components.count - 2] == "versions",
           components[components.count - 3] == "claude",
           name.first?.isNumber == true {
            return .claudeCode
        }
        if name == "codex" || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin")) { return .codex }
        return nil
    }

    /// Whether a tool's binary was started as that tool: argv[0] names the tool's command or the
    /// executable itself (`claude`, a full path, `codex` for `codex-aarch64-apple-darwin`) rather
    /// than a program the binary stands in for.
    static func runsAsItself(_ tool: Tool, executablePath: String, argv0: String?) -> Bool {
        guard let argv0, let name = argv0.split(separator: "/").last else { return true }
        let command = tool == .claudeCode ? "claude" : "codex"
        return name == command || name == executablePath.split(separator: "/").last
    }

    /// The tool a script run by node belongs to: npm's link (`…/bin/claude`, `…/bin/codex`) or a
    /// launcher inside the tool's npm package.
    static func scriptTool(_ script: String) -> Tool? {
        let components = script.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = components.last else { return nil }
        if name == "claude" { return .claudeCode }
        if name == "codex" { return .codex }
        if name.hasPrefix("cli"), isInsidePackage(components, scope: "@anthropic-ai", name: "claude-code") { return .claudeCode }
        if name.hasPrefix("codex"), isInsidePackage(components, scope: "@openai", name: "codex") { return .codex }
        return nil
    }

    /// The index in `arguments` of the script node runs, or nil when it runs none (a REPL, inline
    /// code, or a process that rewrote its argv, like `npm exec`, which leaves empty strings).
    static func nodeScriptIndex(in arguments: [String]) -> Int? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return index + 1 < arguments.count ? index + 1 : nil }
            if nodeInlineCodeOptions.contains(argument) { return nil }
            if argument.hasPrefix("-") {
                index += nodeOptionsWithValue.contains(argument) ? 2 : 1
                continue
            }
            return argument.isEmpty ? nil : index
        }
        return nil
    }

    /// Whether the tool's arguments (after the executable or script) start a session rather than
    /// housekeeping.
    static func isSession(_ tool: Tool, arguments: ArraySlice<String>) -> Bool {
        let (helperFlags, optionsWithValue, commands) = tool == .claudeCode
            ? (claudeHelperFlags, claudeOptionsWithValue, claudeCommands)
            : (codexHelperFlags, codexOptionsWithValue, codexCommands)
        // Everything after `--` is the prompt.
        let options = arguments.prefix { $0 != "--" }
        if options.contains(where: helperFlags.contains) { return false }
        // The subcommand, if any, is the first positional argument.
        var index = options.startIndex
        while index < options.endIndex {
            let argument = options[index]
            if argument.isEmpty || argument.hasPrefix("-") {
                index += optionsWithValue.contains(argument) ? 2 : 1
                continue
            }
            return !commands.contains(argument)
        }
        return true
    }

    /// Whether `components` run through the npm package `scope/name` itself, not a dependency
    /// nested inside it.
    private static func isInsidePackage(_ components: [Substring], scope: String, name: String) -> Bool {
        guard let index = components.indices.dropLast().last(where: { components[$0] == scope && components[$0 + 1] == name })
        else { return false }
        return !components[(index + 2)...].contains("node_modules")
    }

    private static func isScriptRuntime(_ path: String) -> Bool {
        guard let name = path.split(separator: "/", omittingEmptySubsequences: true).last else { return false }
        return scriptRuntimes.contains(String(name))
    }
}
