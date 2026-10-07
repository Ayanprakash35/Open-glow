import Foundation

/// What Music Sync's capture should be doing, decided from everything that matters, so
/// `AppDelegate.reconcileAudio()` only has to carry it out.
enum MusicSyncPlan {
    /// The capture engine, as far as the decision goes.
    enum Engine: Equatable {
        case idle
        /// Idle, with a retry scheduled after a failure: the retry's delay is kept.
        case waitingToRetry
        case starting
        /// Running; `onConnectedDisplay` is false once the display its stream is tied to is gone.
        case running(onConnectedDisplay: Bool)
    }

    enum Step: Equatable {
        /// Already starting, running or due to retry: nothing to do.
        case keep
        case start
        /// Stop the stream and start a new one, on a display that exists.
        case restart
    }

    enum Decision: Equatable {
        /// No reason to capture — Music Sync isn't selected, no overlay is meant to show, or the
        /// glow is paused (sleep, lock, screen saver, another user): stop capture, analysis and
        /// audio frames.
        case off
        /// Wanted, but access is missing: stop everything, show the warning and watch for a grant.
        case awaitingPermission
        /// Capture, analysis and audio frames run.
        case run(Step)
    }

    /// `permission` is only evaluated when capture is otherwise wanted: each evaluation is a
    /// query to the privacy service. It's evaluated while capture runs too, so access revoked
    /// mid-stream ends in `.awaitingPermission` even if the stream itself keeps going.
    static func decide(
        musicSyncSelected: Bool,
        overlayVisible: Bool,
        paused: Bool,
        permission: @autoclosure () -> AudioEngine.PermissionState,
        engine: Engine
    ) -> Decision {
        guard musicSyncSelected, overlayVisible, !paused else { return .off }
        guard permission() == .granted else { return .awaitingPermission }
        switch engine {
        case .idle: return .run(.start)
        case .waitingToRetry, .starting, .running(onConnectedDisplay: true): return .run(.keep)
        case .running(onConnectedDisplay: false): return .run(.restart)
        }
    }
}
