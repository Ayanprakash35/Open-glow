import Foundation
import ScreenCaptureKit
import Testing
@testable import OpenGlow

/// Every ordering of `events`.
private func permutations<T>(_ events: [T]) -> [[T]] {
    guard events.count > 1 else { return [events] }
    return events.indices.flatMap { index -> [[T]] in
        var rest = events
        let first = rest.remove(at: index)
        return permutations(rest).map { [first] + $0 }
    }
}

private func reasons(after events: [ScreenSessionEvent], from start: SessionPauseReasons = []) -> SessionPauseReasons {
    events.reduce(start) { $0.applying($1) }
}

@Suite("Lifecycle: sleep, lock and user switching")
struct SessionPauseTests {
    /// Each pair's "began" half and "ended" half.
    private let pairs: [(ScreenSessionEvent, ScreenSessionEvent)] = [
        (.displaysSlept, .displaysWoke), (.systemWillSleep, .systemDidWake), (.screenLocked, .screenUnlocked),
        (.sessionResignedActive, .sessionBecameActive), (.screenSaverStarted, .screenSaverStopped),
    ]

    @Test func eachReasonPausesUntilItsOwnEnd() {
        for (began, ended) in pairs {
            let paused = reasons(after: [began])
            #expect(!paused.isEmpty, "\(began) should pause")
            #expect(reasons(after: [began, ended]).isEmpty, "\(ended) should resume")
            for (_, otherEnded) in pairs where otherEnded != ended {
                #expect(reasons(after: [began, otherEnded]) == paused, "\(otherEnded) mustn't end \(began)")
            }
        }
    }

    /// Lock, display sleep and system sleep, each beginning before it ends, interleaved in every
    /// possible order: paused exactly while one of them still holds, active at the end.
    @Test func overlappingSleepAndLockEndCorrectlyInAnyOrder() {
        let chosen = Array(pairs.prefix(3))
        let events = chosen.flatMap { [$0.0, $0.1] }
        var orders = 0
        for order in permutations(events) {
            // Only orders where each reason begins before it ends are real.
            let valid = chosen.allSatisfy { pair in
                (order.firstIndex(of: pair.0) ?? 0) < (order.firstIndex(of: pair.1) ?? 0)
            }
            guard valid else { continue }
            orders += 1
            var state: SessionPauseReasons = []
            var open = Set<Int>()
            for event in order {
                state = state.applying(event)
                if let index = chosen.firstIndex(where: { $0.0 == event }) { open.insert(index) }
                if let index = chosen.firstIndex(where: { $0.1 == event }) { open.remove(index) }
                #expect(state.isEmpty == open.isEmpty, "after \(event) in \(order)")
            }
            #expect(state.isEmpty, "\(order) should end active")
        }
        #expect(orders == 90)
    }

    @Test func repeatedOrUnmatchedEventsAreHarmless() {
        #expect(reasons(after: [.screenUnlocked, .displaysWoke, .systemDidWake]).isEmpty)
        #expect(reasons(after: [.screenLocked, .screenLocked, .screenUnlocked]).isEmpty)
        #expect(reasons(after: [.displaysSlept, .displaysSlept]) == .displaysAsleep)
    }

    @Test func aClickOnTheStatusItemProvesTheSessionIsActive() {
        let stuck = reasons(after: [.displaysSlept, .screenLocked, .screenSaverStarted])
        #expect(stuck.applying(.userInteracted).isEmpty)
    }

    @Test func initialStateFromTheLoginSession() {
        typealias Key = SessionPauseReasons.SessionKey
        #expect(SessionPauseReasons.initial(session: nil).isEmpty)
        #expect(SessionPauseReasons.initial(session: [:]).isEmpty)
        #expect(SessionPauseReasons.initial(session: [Key.onConsole: true]).isEmpty)
        #expect(SessionPauseReasons.initial(session: [Key.onConsole: true, Key.screenLocked: true]) == .screenLocked)
        #expect(SessionPauseReasons.initial(session: [Key.onConsole: false]) == .sessionInactive)
        #expect(SessionPauseReasons.initial(session: [Key.onConsole: NSNumber(value: 0), Key.screenLocked: NSNumber(value: 1)]) == [.sessionInactive, .screenLocked])
    }

    @Test func everyEventHasANotification() {
        let mapped = Set(ScreenSessionMonitor.workspaceEvents.values).union(ScreenSessionMonitor.distributedEvents.values)
        #expect(mapped == Set(ScreenSessionEvent.allCases).subtracting([.userInteracted]))
    }

    @Test func descriptionNamesEveryReason() {
        #expect(SessionPauseReasons().description == "active")
        #expect(SessionPauseReasons([.screenLocked, .displaysAsleep]).description == "displays asleep, locked")
    }
}

@Suite("Lifecycle: what capture should do")
struct MusicSyncPlanTests {
    private func decide(
        selected: Bool = true, visible: Bool = true, paused: Bool = false,
        permission: AudioEngine.PermissionState = .granted, engine: MusicSyncPlan.Engine = .idle
    ) -> MusicSyncPlan.Decision {
        MusicSyncPlan.decide(musicSyncSelected: selected, overlayVisible: visible, paused: paused, permission: permission, engine: engine)
    }

    @Test func offUnlessWantedAndActive() {
        #expect(decide(selected: false) == .off)
        #expect(decide(visible: false) == .off)
        #expect(decide(paused: true) == .off)
        // Paused wins even over a running stream and missing access: lock means nothing runs.
        #expect(decide(paused: true, permission: .denied, engine: .running(onConnectedDisplay: true)) == .off)
    }

    @Test func accessIsOnlyCheckedWhenCaptureIsWanted() {
        var checks = 0
        func permission() -> AudioEngine.PermissionState {
            checks += 1
            return .granted
        }
        _ = MusicSyncPlan.decide(musicSyncSelected: true, overlayVisible: true, paused: true, permission: permission(), engine: .idle)
        _ = MusicSyncPlan.decide(musicSyncSelected: false, overlayVisible: true, paused: false, permission: permission(), engine: .idle)
        #expect(checks == 0)
        _ = MusicSyncPlan.decide(musicSyncSelected: true, overlayVisible: true, paused: false, permission: permission(), engine: .running(onConnectedDisplay: true))
        #expect(checks == 1, "a running stream is checked too, so a revoke is noticed")
    }

    @Test func missingAccessStopsEvenARunningStream() {
        for engine: MusicSyncPlan.Engine in [.idle, .waitingToRetry, .starting, .running(onConnectedDisplay: true)] {
            #expect(decide(permission: .denied, engine: engine) == .awaitingPermission)
            #expect(decide(permission: .unknown, engine: engine) == .awaitingPermission)
        }
    }

    @Test func engineSteps() {
        #expect(decide(engine: .idle) == .run(.start))
        #expect(decide(engine: .waitingToRetry) == .run(.keep), "a scheduled retry keeps its backoff")
        #expect(decide(engine: .starting) == .run(.keep))
        #expect(decide(engine: .running(onConnectedDisplay: true)) == .run(.keep))
        #expect(decide(engine: .running(onConnectedDisplay: false)) == .run(.restart))
    }

    /// Music plays; the screen locks, the Mac sleeps, wakes still locked, and unlocks.
    @Test func lockAndSleepDuringMusicStopAndResumeCapture() {
        var session: SessionPauseReasons = []
        var engine = MusicSyncPlan.Engine.running(onConnectedDisplay: true)
        var decisions: [MusicSyncPlan.Decision] = []
        for event: ScreenSessionEvent in [.screenLocked, .displaysSlept, .systemWillSleep, .systemDidWake, .displaysWoke, .screenUnlocked] {
            session = session.applying(event)
            let decision = decide(paused: !session.isEmpty, engine: engine)
            decisions.append(decision)
            if decision == .off { engine = .idle }
        }
        #expect(decisions == [.off, .off, .off, .off, .off, .run(.start)])
    }
}

@Suite("Lifecycle: retries and access")
struct CaptureRecoveryTests {
    @Test func retriesBackOffAndRepeatTheLastDelay() {
        var retry = CaptureRetry()
        let delays = (0..<6).map { _ in retry.next(afterRunningFor: 0) }
        #expect(delays == [1, 2, 5, 10, 10, 10])
        #expect(retry.attempts == 6)
    }

    @Test func aHealthyRunStartsTheScheduleOver() {
        var retry = CaptureRetry()
        _ = retry.next(afterRunningFor: 0)
        _ = retry.next(afterRunningFor: 0)
        #expect(retry.next(afterRunningFor: CaptureRetryConfig.healthyRunDuration) == CaptureRetryConfig.restartDelays[0])
        retry.reset()
        #expect(retry.attempts == 0)
    }

    /// One drop (a headphone unplug, say) that comes straight back never shows as a failure.
    @Test func onlyARetryThatFailsTooReportsTheFailure() {
        var retry = CaptureRetry()
        #expect(!retry.reportsFailure)
        _ = retry.next(afterRunningFor: 0)
        #expect(!retry.reportsFailure)
        _ = retry.next(afterRunningFor: 0)
        #expect(retry.reportsFailure)
    }

    @Test func delaysAreAscendingAndInRange() {
        for delays in [CaptureRetryConfig.restartDelays, CaptureRetryConfig.permissionCheckDelays] {
            #expect(delays == delays.sorted())
            #expect(delays.allSatisfy { $0 >= 0.5 && $0 <= 60 })
            #expect(CaptureRetryConfig.delay(delays, attempt: -1) == delays[0])
            #expect(CaptureRetryConfig.delay(delays, attempt: 1000) == delays.last)
        }
    }

    /// Access revoked mid-stream, then granted again — sometimes only for ScreenCaptureKit after
    /// a relaunch, which is why its refusal outvotes the preflight until something changes.
    @Test func aRefusalHoldsUntilAccessIsSeenMissingOrTheUserRetries() {
        var access = CaptureAccess()
        #expect(access.evaluate(preflight: true) == .granted)

        access.captureRefused()
        #expect(access.evaluate(preflight: true) == .denied, "no retry loop on the preflight's word")
        #expect(access.evaluate(preflight: true) == .denied)

        #expect(access.evaluate(preflight: false) == .denied)
        #expect(access.evaluate(preflight: true) == .granted, "a grant after access was seen missing is fresh")

        access.captureRefused()
        access.userRetried()
        #expect(access.evaluate(preflight: true) == .granted)
    }

    @Test func stopCauses() {
        #expect(CaptureStopCause.classify(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)) == .accessDenied)
        #expect(CaptureStopCause.classify(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)) == .userStopped)
        #expect(CaptureStopCause.classify(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)) == .failed)
        #expect(CaptureStopCause.classify(NSError(domain: NSOSStatusErrorDomain, code: -3801)) == .failed)
        #expect(CaptureStopCause.classify(CancellationError()) == .failed)
    }
}

@Suite("Lifecycle: status")
struct MusicSyncStatusResolveTests {
    private let playing: AudioAnalysisState = {
        var state = AudioAnalysisState()
        state.hasAudio = true
        state.isSilent = false
        return state
    }()

    private func resolve(
        permission: AudioEngine.PermissionState = .granted,
        capture: MusicSyncStatus.Capture,
        reportsFailure: Bool = false,
        analysis: AudioAnalysisState = AudioAnalysisState()
    ) -> MusicSyncStatus {
        .resolve(overlayVisible: true, musicSyncSelected: true, permission: permission, capture: capture, reportsFailure: reportsFailure, analysis: analysis)
    }

    @Test func offAndSteadyComeFirst() {
        #expect(MusicSyncStatus.resolve(overlayVisible: false, musicSyncSelected: true, permission: .denied, capture: .notRunning(lastFailure: nil), reportsFailure: true, analysis: playing) == .off)
        #expect(MusicSyncStatus.resolve(overlayVisible: true, musicSyncSelected: false, permission: .denied, capture: .notRunning(lastFailure: nil), reportsFailure: true, analysis: playing) == .steady)
    }

    /// Revoked access ends in the warning that asks for access, never in "capture failed".
    @Test func missingAccessOutranksAnyCaptureFailure() {
        let failure = CaptureFailure(cause: .failed, reason: "The stream stopped")
        #expect(resolve(permission: .denied, capture: .notRunning(lastFailure: failure), reportsFailure: true) == .needsPermission)
        #expect(resolve(permission: .denied, capture: .running(CaptureHealth()), analysis: playing) == .needsPermission)
        #expect(MusicSyncStatus.needsPermission.needsAttention)
    }

    @Test func silenceWhileRunningIsNotAFailure() {
        // No buffers at all (the stream went quiet after a device change) and plain silence.
        #expect(resolve(capture: .running(CaptureHealth())) == .listening(receivingAudio: false))
        var silent = AudioAnalysisState()
        silent.hasAudio = true
        #expect(resolve(capture: .running(CaptureHealth()), analysis: silent) == .listening(receivingAudio: false))
        #expect(resolve(capture: .running(CaptureHealth(droppedBuffers: 3, droppedInARow: 3))) == .listening(receivingAudio: false))
        #expect(resolve(capture: .running(CaptureHealth()), analysis: playing) == .listening(receivingAudio: true))
    }

    @Test func aRunOfUnreadableBuffersIsReported() {
        let run = AudioEngineConfig.unreadableBufferRun
        #expect(resolve(capture: .running(CaptureHealth(droppedBuffers: run, droppedInARow: run))) == .captureUnreadable)
    }

    @Test func failuresShowOnlyOnceARetryFailedToo() {
        let failure = CaptureFailure(cause: .failed, reason: "The device changed")
        #expect(resolve(capture: .notRunning(lastFailure: nil), reportsFailure: true) == .starting)
        #expect(resolve(capture: .notRunning(lastFailure: failure)) == .starting)
        #expect(resolve(capture: .notRunning(lastFailure: failure), reportsFailure: true) == .captureFailed(reason: "The device changed."))
        let unreadable = CaptureFailure(cause: .unreadable, reason: "Unreadable.")
        #expect(resolve(capture: .notRunning(lastFailure: unreadable), reportsFailure: true) == .captureUnreadable)
    }
}
