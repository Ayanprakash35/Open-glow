import Foundation
import os

/// The "coding-session glow" option: a short sweep in the tool's own colors whenever a Claude Code
/// or Codex session starts on this Mac.
@MainActor
final class CodingSessionGlow {
    private let monitor = CodingSessionMonitor()
    private let displayManager: DisplayManager
    private let logger = Logger(subsystem: "com.openglow.app", category: "CodingSessions")

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
        monitor.onSessionStarted = { [weak self] tool in self?.sessionStarted(tool) }
    }

    /// Watches for new sessions only while the option is on and the glow is shown at all.
    func update(enabled: Bool) {
        if enabled, !monitor.isStarted {
            monitor.start()
        } else if !enabled, monitor.isStarted {
            monitor.stop()
        }
    }

    private func sessionStarted(_ tool: CodingSessionMonitor.Tool) {
        logger.notice("\(tool.displayName, privacy: .public) session started")
        displayManager.playAccent(tool.palette)
    }
}
