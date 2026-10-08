import Foundation
import os

/// Process polling.
enum CodingSessionConfig {
    /// Seconds between scans of the process table while started — the longest a new session waits
    /// for its glow. Measured with ~530 processes (release build): a scan where nothing new
    /// started takes 0.03–0.25 ms (mostly listing the PIDs); the baseline scan at `start()`,
    /// which reads every process's path once, 3–20 ms depending on load. Sane range: 0.5–3.
    static let pollInterval: TimeInterval = 1.5
    /// Seconds a scan may drift so macOS can batch it with other wakeups. Sane range:
    /// 0–pollInterval/2.
    static let pollTolerance: TimeInterval = 0.5
}

/// Each tool's glow colors, sRGB 0...1.
enum CodingSessionColors {
    /// Claude's terra-cotta orange, #D97757 — the accent of Claude's brand and Claude Code's
    /// terminal UI.
    static let claudeTerracotta = PaletteColor(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    /// A soft warm peach-cream, #F5CDB0, so the gradient stays warm where it fades from the orange.
    static let claudePeach = PaletteColor(red: 0xF5 / 255.0, green: 0xCD / 255.0, blue: 0xB0 / 255.0)
    /// Share of the way around the screen the orange covers. 0...1.
    static let claudeBalance = 0.6

    /// A saturated indigo/blue-violet, #6366F1, after the cool blue-violet of the Codex app icon
    /// (an approximation, not an official brand value). Deeper and more saturated than the
    /// default "Mist" palette's pastels, so the two don't read alike.
    static let codexIndigo = PaletteColor(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0)
    /// A cool, faintly blue white, #E6ECFF, after OpenAI's monochrome identity.
    static let codexCoolWhite = PaletteColor(red: 0xE6 / 255.0, green: 0xEC / 255.0, blue: 0xFF / 255.0)
    /// Share of the way around the screen the indigo covers. 0...1.
    static let codexBalance = 0.6
}

/// Reports each Claude Code or Codex session that starts, by polling the process table off the
/// main thread (see `CodingSessionMatcher` for what counts as a session, `CodingSessionTracker`
/// for the debouncing). Public process APIs only, nothing that needs a permission prompt.
///
/// Meant to live as long as the app; call `stop()` before letting go of one.
@MainActor
final class CodingSessionMonitor {
    enum Tool: String, CaseIterable, Sendable {
        case claudeCode, codex

        var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            }
        }

        /// The tool's colors for the glow.
        var palette: GlowPalette {
            switch self {
            case .claudeCode:
                GlowPalette(primary: CodingSessionColors.claudeTerracotta, secondary: CodingSessionColors.claudePeach,
                            balance: CodingSessionColors.claudeBalance)
            case .codex:
                GlowPalette(primary: CodingSessionColors.codexIndigo, secondary: CodingSessionColors.codexCoolWhite,
                            balance: CodingSessionColors.codexBalance)
            }
        }
    }

    /// Main actor, once per newly started session (not for sessions already running at `start()`).
    var onSessionStarted: ((Tool) -> Void)?

    private let logger = Logger(subsystem: "com.openglow.app", category: "CodingSessions")
    private let table: any ProcessTable & Sendable
    private let interval: TimeInterval
    private let tolerance: TimeInterval
    private let cooldown: TimeInterval
    private var pollTask: Task<Void, Never>?
    /// Bumped by every start and stop, so a report from a superseded polling task is dropped.
    private var generation = 0

    /// `table`, `interval`, `tolerance` and `cooldown` are there for tests.
    init(
        table: any ProcessTable & Sendable = LiveProcessTable(),
        interval: TimeInterval = CodingSessionConfig.pollInterval,
        tolerance: TimeInterval = CodingSessionConfig.pollTolerance,
        cooldown: TimeInterval = CodingSessionTrackerConfig.cooldown
    ) {
        self.table = table
        self.interval = interval
        self.tolerance = tolerance
        self.cooldown = cooldown
    }

    var isStarted: Bool { pollTask != nil }

    func start() {
        guard pollTask == nil else { return }
        generation += 1
        let generation = self.generation
        let (table, interval, tolerance, cooldown) = (self.table, self.interval, self.tolerance, self.cooldown)
        pollTask = Task.detached(priority: .utility) { [weak self] in
            var tracker = CodingSessionTracker(cooldown: cooldown)
            // The first scan is the baseline: sessions running now are never reported.
            while !Task.isCancelled, self != nil {
                let started = tracker.scan(table, now: ProcessInfo.processInfo.systemUptime)
                if !started.isEmpty { await self?.report(started, generation: generation) }
                do {
                    try await Task.sleep(for: .seconds(interval), tolerance: .seconds(tolerance))
                } catch {
                    return
                }
            }
        }
        logger.notice("Coding session monitor started")
    }

    func stop() {
        guard let task = pollTask else { return }
        task.cancel()
        pollTask = nil
        generation += 1
        logger.notice("Coding session monitor stopped")
    }

    /// Not logged here: `onSessionStarted`'s owner logs each start along with what it did.
    private func report(_ tools: [Tool], generation: Int) {
        guard generation == self.generation else { return }
        for tool in tools {
            onSessionStarted?(tool)
        }
    }
}
