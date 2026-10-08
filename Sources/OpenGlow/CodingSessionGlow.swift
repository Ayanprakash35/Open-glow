import Foundation
import os

/// The "coding-session glow" option: a short sweep in the tool's own colors whenever a Claude Code
/// or Codex session starts on this Mac, for each tool the user chose.
@MainActor
final class CodingSessionGlow {
    private typealias Tool = CodingSessionMonitor.Tool

    private let monitor: CodingSessionMonitor
    private let settings: Settings
    private let play: @MainActor (GlowPalette) -> Void
    private let logger = Logger(subsystem: "com.openglow.app", category: "CodingSessions")

    convenience init(displayManager: DisplayManager, settings: Settings = .shared) {
        self.init(monitor: CodingSessionMonitor(), settings: settings) { displayManager.playAccent($0) }
    }

    /// `monitor` and `play` are there for tests.
    init(monitor: CodingSessionMonitor, settings: Settings, play: @escaping @MainActor (GlowPalette) -> Void) {
        self.monitor = monitor
        self.settings = settings
        self.play = play
        monitor.onSessionStarted = { [weak self] tool in self?.sessionStarted(tool) }
    }

    /// Watches for new sessions only while the option is on, the glow is shown at all and at
    /// least one tool is chosen, so with none chosen the process table isn't read either.
    func update(enabled: Bool) {
        let watches = enabled && Tool.allCases.contains { settings.glowsForCodingSession($0) }
        if watches, !monitor.isStarted {
            monitor.start()
        } else if !watches, monitor.isStarted {
            monitor.stop()
        }
    }

    private func sessionStarted(_ tool: Tool) {
        // Asked now rather than when the monitor started: the choice can change at any time.
        guard settings.glowsForCodingSession(tool) else {
            logger.info("\(tool.displayName, privacy: .public) session started; its glow is off")
            return
        }
        logger.notice("\(tool.displayName, privacy: .public) session started")
        play(tool.palette)
    }
}
