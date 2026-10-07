import Foundation

/// What Music Sync is doing right now, as shown in the popover and menu.
enum MusicSyncStatus: Equatable {
    /// Open Glow is turned off, or every display is unchecked — nothing is drawn or captured.
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
