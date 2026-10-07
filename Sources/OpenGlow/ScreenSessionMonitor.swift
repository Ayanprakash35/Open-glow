import AppKit
import os

/// Why the glow is paused. While any is set nothing is drawn and nothing is captured; each
/// reason is set and cleared by its own pair of events, so overlapping sleep, lock, screen saver
/// and user switching end in the right state whatever order they arrive in.
struct SessionPauseReasons: OptionSet, Hashable, Sendable, CustomStringConvertible {
    let rawValue: Int

    static let displaysAsleep = SessionPauseReasons(rawValue: 1 << 0)
    static let systemAsleep = SessionPauseReasons(rawValue: 1 << 1)
    /// The lock screen is up. Nothing is drawn on it.
    static let screenLocked = SessionPauseReasons(rawValue: 1 << 2)
    /// Fast user switching moved this session off the console.
    static let sessionInactive = SessionPauseReasons(rawValue: 1 << 3)
    /// The screen saver runs on the same window level as the overlay, which would draw over it.
    static let screenSaver = SessionPauseReasons(rawValue: 1 << 4)

    private static let names: [(SessionPauseReasons, String)] = [
        (.displaysAsleep, "displays asleep"), (.systemAsleep, "system asleep"), (.screenLocked, "locked"),
        (.sessionInactive, "session inactive"), (.screenSaver, "screen saver"),
    ]

    var description: String {
        let parts = Self.names.filter { contains($0.0) }.map(\.1)
        return parts.isEmpty ? "active" : parts.joined(separator: ", ")
    }

    /// The reasons after `event`.
    func applying(_ event: ScreenSessionEvent) -> SessionPauseReasons {
        switch event {
        case .displaysSlept: union(.displaysAsleep)
        case .displaysWoke: subtracting(.displaysAsleep)
        case .systemWillSleep: union(.systemAsleep)
        case .systemDidWake: subtracting(.systemAsleep)
        case .screenLocked: union(.screenLocked)
        case .screenUnlocked: subtracting(.screenLocked)
        case .sessionResignedActive: union(.sessionInactive)
        case .sessionBecameActive: subtracting(.sessionInactive)
        case .screenSaverStarted: union(.screenSaver)
        case .screenSaverStopped: subtracting(.screenSaver)
        // Clicking the status item is impossible while any of these holds, so a click proves
        // they're all over — which also heals a state stuck by a missed notification.
        case .userInteracted: []
        }
    }

    /// The reasons that already hold at launch, read from the login session's description
    /// (`CGSessionCopyCurrentDictionary`) — a relaunch while locked or switched out mustn't draw
    /// until the matching "ended" notification. The lock flag is an undocumented key, so a
    /// missing one counts as unlocked.
    static func initial(session: [String: Any]?) -> SessionPauseReasons {
        guard let session else { return [] }
        var reasons: SessionPauseReasons = []
        if session[SessionKey.onConsole] as? Bool == false { reasons.insert(.sessionInactive) }
        if session[SessionKey.screenLocked] as? Bool == true { reasons.insert(.screenLocked) }
        return reasons
    }

    enum SessionKey {
        /// `kCGSessionOnConsoleKey`.
        static let onConsole = "kCGSSessionOnConsoleKey"
        static let screenLocked = "CGSSessionScreenIsLocked"
    }
}

enum ScreenSessionEvent: CaseIterable, Sendable {
    case displaysSlept, displaysWoke
    case systemWillSleep, systemDidWake
    case screenLocked, screenUnlocked
    case sessionResignedActive, sessionBecameActive
    case screenSaverStarted, screenSaverStopped
    case userInteracted
}

/// Watches display and system sleep, the lock screen, the screen saver and fast user switching,
/// and reports when the glow should pause or resume.
///
/// Lock and screen-saver state come from loginwindow's and the screen saver's distributed
/// notifications — the only public signals for them; sleep and user switching from NSWorkspace.
@MainActor
final class ScreenSessionMonitor: NSObject {
    /// NSWorkspace notifications and what each means.
    nonisolated static let workspaceEvents: [Notification.Name: ScreenSessionEvent] = [
        NSWorkspace.screensDidSleepNotification: .displaysSlept,
        NSWorkspace.screensDidWakeNotification: .displaysWoke,
        NSWorkspace.willSleepNotification: .systemWillSleep,
        NSWorkspace.didWakeNotification: .systemDidWake,
        NSWorkspace.sessionDidResignActiveNotification: .sessionResignedActive,
        NSWorkspace.sessionDidBecomeActiveNotification: .sessionBecameActive,
    ]

    /// Distributed notifications and what each means.
    nonisolated static let distributedEvents: [String: ScreenSessionEvent] = [
        "com.apple.screenIsLocked": .screenLocked,
        "com.apple.screenIsUnlocked": .screenUnlocked,
        "com.apple.screensaver.didstart": .screenSaverStarted,
        "com.apple.screensaver.didstop": .screenSaverStopped,
    ]

    private let logger = Logger(subsystem: "com.openglow.app", category: "Session")
    private(set) var reasons: SessionPauseReasons

    var isPaused: Bool { !reasons.isEmpty }

    /// Main actor, whenever `reasons` changes.
    var onChange: ((_ old: SessionPauseReasons, _ new: SessionPauseReasons) -> Void)?

    override init() {
        reasons = SessionPauseReasons.initial(session: CGSessionCopyCurrentDictionary() as? [String: Any])
        super.init()
        if isPaused { logger.notice("Session at launch: \(self.reasons.description, privacy: .public)") }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in Self.workspaceEvents.keys {
            workspace.addObserver(self, selector: #selector(workspaceNotification(_:)), name: name, object: nil)
        }
        // Only the selector-based registration takes a suspension behavior, and every other one
        // holds notifications back while the app is inactive — which for a menu-bar app is
        // nearly always.
        let distributed = DistributedNotificationCenter.default()
        for name in Self.distributedEvents.keys {
            distributed.addObserver(
                self, selector: #selector(distributedNotification(_:)), name: Notification.Name(name),
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
    }

    /// Folds `event` in and reports the change, if any.
    func handle(_ event: ScreenSessionEvent) {
        let old = reasons
        reasons = old.applying(event)
        guard reasons != old else { return }
        logger.notice("Session: \(self.reasons.description, privacy: .public)")
        onChange?(old, reasons)
    }

    // Every event takes the same hop to the main actor, whichever thread a center calls on, so
    // a lock and its unlock can't overtake each other.
    @objc nonisolated private func workspaceNotification(_ notification: Notification) {
        guard let event = Self.workspaceEvents[notification.name] else { return }
        deliver(event)
    }

    @objc nonisolated private func distributedNotification(_ notification: Notification) {
        guard let event = Self.distributedEvents[notification.name.rawValue] else { return }
        deliver(event)
    }

    nonisolated private func deliver(_ event: ScreenSessionEvent) {
        Task { @MainActor [weak self] in self?.handle(event) }
    }
}
