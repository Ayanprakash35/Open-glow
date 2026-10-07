import Foundation
import ScreenCaptureKit

/// Retry and re-check timing for Music Sync's capture.
enum CaptureRetryConfig {
    /// Seconds before retrying after capture fails to start or stops unexpectedly; the last value
    /// repeats for further attempts. Sane range: 0.5–30 each, ascending.
    static let restartDelays: [Double] = [1, 2, 5, 10]
    /// Seconds a stream must have run before it stopped to count as healthy: the retry schedule
    /// then starts over instead of continuing to back off. Sane range: 10–120.
    static let healthyRunDuration: TimeInterval = 30
    /// Retries that show as "Starting…" before the status admits capture is failing — a stream
    /// that drops once (an output-device change, say) and comes straight back shouldn't flash a
    /// warning. Sane range: 0–3.
    static let quietRetries = 1
    /// Seconds between checks for Screen & System Audio Recording access while Music Sync waits
    /// for it, so a grant (or a re-grant after revoking) takes effect without reopening the menu.
    /// Starts quick after the user acts and settles on the last value. Each check is one cheap
    /// query to the privacy service that never prompts. Sane range: 1–60 each, ascending.
    static let permissionCheckDelays: [Double] = [1, 2, 3, 5, 10, 15]

    /// The delay for `attempt` (0-based) in `delays`, repeating the last one.
    static func delay(_ delays: [Double], attempt: Int) -> Double {
        delays[min(max(attempt, 0), delays.count - 1)]
    }
}

/// Why capture stopped, or failed to start, as far as the app's reaction goes.
enum CaptureStopCause: Equatable, Sendable {
    /// The user stopped it from the system's capture indicator.
    case userStopped
    /// ScreenCaptureKit refused: Screen & System Audio Recording access is missing or was
    /// revoked. Retrying can't help until access changes.
    case accessDenied
    /// Buffers kept arriving but none could be read, so the engine gave the stream up. A new
    /// stream negotiates its format afresh, so this is retried.
    case unreadable
    /// Anything else — an output-device change, a display going away — which is worth retrying.
    case failed

    static func classify(_ error: any Error) -> CaptureStopCause {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return .failed }
        switch SCStreamError.Code(rawValue: error.code) {
        case .userStopped: return .userStopped
        case .userDeclined: return .accessDenied
        default: return .failed
        }
    }
}

/// Why capture most recently failed, for the status.
struct CaptureFailure: Equatable, Sendable {
    var cause: CaptureStopCause
    /// One sentence for the popover.
    var reason: String
}

/// How readable the running stream's buffers have been.
struct CaptureHealth: Equatable, Sendable {
    /// Buffers that couldn't be read since capture started.
    var droppedBuffers = 0
    /// How many of the most recent buffers in a row couldn't be read; 0 once one is read again.
    var droppedInARow = 0

    /// Buffers keep arriving and none of the latest can be read. A stream that delivers nothing
    /// at all (silence after a device change, say) is never unreadable.
    var isUnreadable: Bool { droppedInARow >= AudioEngineConfig.unreadableBufferRun }
}

/// The retry schedule for capture that stops or fails without being asked to.
struct CaptureRetry: Equatable {
    /// Retries scheduled in the current failure episode.
    private(set) var attempts = 0

    /// Schedules one more retry and returns its delay. A stream that ran healthily before it
    /// stopped starts a new episode.
    mutating func next(afterRunningFor ranFor: TimeInterval) -> Double {
        if ranFor >= CaptureRetryConfig.healthyRunDuration { attempts = 0 }
        let delay = CaptureRetryConfig.delay(CaptureRetryConfig.restartDelays, attempt: attempts)
        attempts += 1
        return delay
    }

    /// Ends the episode: capture was stopped on purpose, or the screens woke or unlocked.
    mutating func reset() {
        attempts = 0
    }

    /// Whether a failure should show as one: only once a retry has itself failed.
    var reportsFailure: Bool { attempts > CaptureRetryConfig.quietRetries }
}

/// Screen & System Audio Recording access as Music Sync sees it: macOS's preflight answer,
/// overruled while ScreenCaptureKit itself refuses to capture.
///
/// The two can disagree — right after access is granted to a running app, the preflight can say
/// yes while ScreenCaptureKit still refuses until a relaunch. Retrying on the preflight's word
/// alone would loop forever, so a refusal holds until access is seen missing (the next grant is
/// then a fresh one) or the user asks to try again.
struct CaptureAccess: Equatable {
    private(set) var refusedByCapture = false

    /// Combines a fresh preflight answer with what ScreenCaptureKit last said.
    mutating func evaluate(preflight: Bool) -> AudioEngine.PermissionState {
        guard preflight else {
            refusedByCapture = false
            return .denied
        }
        return refusedByCapture ? .denied : .granted
    }

    /// ScreenCaptureKit refused to capture (`SCStreamError.userDeclined`).
    mutating func captureRefused() {
        refusedByCapture = true
    }

    /// The user opened the menu or the popover, or clicked Grant Access: worth one more try.
    mutating func userRetried() {
        refusedByCapture = false
    }
}
