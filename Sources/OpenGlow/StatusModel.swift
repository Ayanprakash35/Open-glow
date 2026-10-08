import Foundation

/// What Music Sync is doing right now, as shown in the popover and menu.
enum MusicSyncStatus: Equatable {
    /// Open Glow is turned off, or every display is unchecked — nothing is drawn or captured.
    /// `Settings.isEnabled` tells the two apart where the difference is shown (the popover, the
    /// welcome tour, `StatusIcon`).
    case off
    case steady
    case needsPermission
    case starting
    case listening(receivingAudio: Bool)
    case captureFailed(reason: String)
    /// Capture delivers buffers, but none of them can be read — and fresh streams didn't help.
    case captureUnreadable

    var needsAttention: Bool {
        switch self {
        case .needsPermission, .captureFailed, .captureUnreadable: true
        default: false
        }
    }

    /// Where capture stands, for `resolve`.
    enum Capture: Equatable {
        /// Idle, starting, or waiting to retry; `lastFailure` is why it last failed, nil after a
        /// deliberate stop.
        case notRunning(lastFailure: CaptureFailure?)
        case running(CaptureHealth)
    }

    /// The status everything adds up to. A capture failure only shows once a retry has failed
    /// too (`reportsFailure`), and then keeps showing while the next retry starts: a stream that
    /// drops once and comes back reads as starting, and one that keeps failing doesn't flicker.
    static func resolve(
        overlayVisible: Bool,
        musicSyncSelected: Bool,
        permission: AudioEngine.PermissionState,
        capture: Capture,
        reportsFailure: Bool,
        analysis: AudioAnalysisState
    ) -> MusicSyncStatus {
        guard overlayVisible else { return .off }
        guard musicSyncSelected else { return .steady }
        guard permission == .granted else { return .needsPermission }
        switch capture {
        case .running(let health):
            // Judged on the latest buffers only: one bad buffer long ago, followed by silence,
            // isn't a broken capture — and silence itself never is.
            if health.isUnreadable { return .captureUnreadable }
            return .listening(receivingAudio: analysis.hasAudio && !analysis.isSilent)
        case .notRunning(let failure):
            guard let failure, reportsFailure else { return .starting }
            switch failure.cause {
            case .unreadable: return .captureUnreadable
            case .failed, .accessDenied, .userStopped:
                let reason = failure.reason
                return .captureFailed(reason: reason.hasSuffix(".") ? reason : reason + ".")
            }
        }
    }
}

/// The menu-bar icon for a status, while no timer's countdown stands in for it.
struct StatusIcon: Equatable {
    /// SF Symbol name.
    var symbol: String
    /// The tooltip, which is also the image's VoiceOver description.
    var description: String
    /// Dimmed while nothing is drawn.
    var appearsDisabled: Bool
    /// The everyday state, the one the app's own logo stands in for when the bundle has one.
    var isNormal: Bool
    /// Music Sync can't work and the user should know: the icon, or a running timer, warns.
    var isWarning: Bool

    init(symbol: String, description: String, appearsDisabled: Bool = false, isNormal: Bool = false, isWarning: Bool = false) {
        self.symbol = symbol
        self.description = description
        self.appearsDisabled = appearsDisabled
        self.isNormal = isNormal
        self.isWarning = isWarning
    }

    /// `glowEnabled` is the master switch: with it on, `.off` means every display is unchecked.
    init(status: MusicSyncStatus, glowEnabled: Bool) {
        switch status {
        case .off:
            let description = glowEnabled
                ? "Open Glow — no display is selected. Turn one on under Displays."
                : "Open Glow — off"
            self.init(symbol: "light.min", description: description, appearsDisabled: true)
        case .needsPermission:
            self.init(symbol: Self.warningSymbol, description: "Open Glow needs Screen & System Audio Recording access for Music Sync", isWarning: true)
        case .captureFailed:
            self.init(symbol: Self.warningSymbol, description: "Open Glow can't capture audio for Music Sync", isWarning: true)
        case .captureUnreadable:
            self.init(symbol: Self.warningSymbol, description: "Open Glow can't read the captured audio for Music Sync", isWarning: true)
        case .steady, .starting, .listening:
            self.init(symbol: "light.max", description: "Open Glow", isNormal: true)
        }
    }

    static let warningSymbol = "exclamationmark.triangle"

    /// The warning a running timer's countdown shows in the icon's place; nil when there's none.
    var timerAttention: TimerAttention? {
        isWarning ? TimerAttention(symbol: symbol, description: description) : nil
    }
}

extension NowPlayingMonitor.Player {
    /// The players album colors follow, from the two settings.
    static func followed(appleMusic: Bool, spotify: Bool) -> Set<Self> {
        var players: Set<Self> = []
        if appleMusic { players.insert(.music) }
        if spotify { players.insert(.spotify) }
        return players
    }
}

extension NowPlayingMonitor.Status {
    /// The status as the popover shows it when album colors follow only `players`: a track, or
    /// an Automation problem, from any other player reads as nothing playing. It can't color the
    /// glow, so naming it beside the swatch would only mislead.
    func shown(following players: Set<NowPlayingMonitor.Player>) -> Self {
        switch self {
        case .playing(let track) where !players.contains(track.player):
            .notPlaying
        case .notAuthorized(let player) where !players.contains(player):
            .notPlaying
        default:
            self
        }
    }
}

struct DisplayInfo: Identifiable, Equatable {
    let uuid: String
    let name: String
    let hasNotch: Bool
    var id: String { uuid }
}

/// Live state the popover shows beside the settings themselves. `AppDelegate` refreshes it while
/// the popover is open, so it follows capture starting, audio arriving and tracks changing
/// instead of freezing at the moment it opened.
@MainActor
@Observable
final class StatusModel {
    var musicSync: MusicSyncStatus = .starting
    var nowPlaying: NowPlayingMonitor.Status = .stopped
    /// The palette on screen, for the preview swatch.
    var palette: GlowPalette = .fallback
    var albumArtSource: ColorExtractor.Source?
    var launchAtLogin: LaunchAtLogin.State = .disabled
    var launchAtLoginError: String?
    var displays: [DisplayInfo] = []
    /// The system-wide Reduce Motion accessibility setting, which holds the glow still.
    var systemReducesMotion = false
}
