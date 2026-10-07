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
    /// Capture is running and delivering buffers, but none of them can be read. Retrying the same
    /// stream won't help, so this doesn't claim to.
    case captureUnreadable

    var needsAttention: Bool {
        switch self {
        case .needsPermission, .captureFailed, .captureUnreadable: true
        default: false
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
