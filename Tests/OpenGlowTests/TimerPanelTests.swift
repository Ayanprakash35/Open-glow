import AppKit
import Observation
import SwiftUI
import Testing
@testable import OpenGlow

private let minute: TimeInterval = 60

@Suite("Timer panel model")
@MainActor
struct TimerPanelModelTests {
    private final class Log {
        var calls: [String] = []
        var customMinutes: Int? = 20
    }

    private func model(_ log: Log, plan: PomodoroPlan = .standard) -> TimerPanelModel {
        TimerPanelModel(plan: plan, actions: TimerMenu.Actions(
            startCountdown: { log.calls.append("countdown \(Int($0))") },
            startPomodoro: { log.calls.append("pomodoro \(Int($0.focus / 60))/\(Int($0.shortBreak / 60))") },
            pause: { log.calls.append("pause") },
            resume: { log.calls.append("resume") },
            skipPhase: { log.calls.append("skip \($0) \($1.map(String.init) ?? "-")") },
            cancel: { log.calls.append("cancel") },
            askForCustomMinutes: { log.calls.append("ask"); return log.customMinutes }
        ))
    }

    private func snapshot(_ kind: TimerKind, round: Int?) -> TimerSnapshot {
        TimerSnapshot(kind: kind, remaining: 100, duration: 300, round: round, rounds: round.map { _ in 4 }, isPaused: false, isLastPhase: false)
    }

    @Test func offersTheMenuPresetsAndThePlan() {
        let log = Log()
        let plan = PomodoroPlan(focus: 50 * minute, shortBreak: 10 * minute, longBreak: 30 * minute, roundsPerSet: 3, repeats: false)
        let model = model(log, plan: plan)
        #expect(model.snapshot == nil)
        #expect(model.presetMinutes == TimerMenuConfig.presetMinutes)
        #expect(model.pomodoroTitle == "Start Pomodoro (50/10)")
        model.startCountdown(minutes: 5)
        model.startCountdown(minutes: 60)
        model.startPomodoro()
        #expect(log.calls == ["countdown 300", "countdown 3600", "pomodoro 50/10"])
    }

    @Test func customAsksThenStartsOrNot() {
        let log = Log()
        let model = model(log)
        model.startCustomCountdown()
        log.customMinutes = nil
        model.startCustomCountdown()
        #expect(log.calls == ["ask", "countdown 1200", "ask"])
    }

    @Test func controlsRouteToTheirActions() {
        let log = Log()
        let model = model(log)
        model.pause()
        model.resume()
        model.cancel()
        #expect(log.calls == ["pause", "resume", "cancel"])
    }

    @Test func skipNamesThePhaseOnScreenNotTheLatest() {
        let log = Log()
        let model = model(log)
        // The view drew focus 1; a tick has since moved the model on to the break.
        let shown = snapshot(.focus, round: 1)
        model.snapshot = snapshot(.shortBreak, round: 1)
        model.skipPhase(shown: shown)
        #expect(log.calls == ["skip focus 1"])
    }

    @Test func snapshotChangesAreObservedButActionSwapsAreNot() {
        let model = model(Log())
        let snapshotChanged = Flag()
        withObservationTracking { _ = model.snapshot } onChange: { snapshotChanged.isSet = true }
        model.snapshot = snapshot(.countdown, round: nil)
        #expect(snapshotChanged.isSet)

        let actionsChanged = Flag()
        withObservationTracking { _ = model.actions } onChange: { actionsChanged.isSet = true }
        model.actions.cancel = {}
        #expect(!actionsChanged.isSet)
    }

    /// Wired to a real controller the way `TimerPresenter` wires it.
    @Test func drivesARealControllerAndKeepsTheBreak() throws {
        let clock = PanelTestClock()
        let controller = TimerController(clock: { clock.now }, playSound: {})
        let model = TimerPanelModel(actions: TimerMenu.Actions(controller: controller))
        controller.onUpdate = { model.snapshot = $0 }

        model.startPomodoro()
        let focus = try #require(model.snapshot)
        #expect(focus.kind == .focus && focus.round == 1 && focus.remaining == 25 * minute)
        clock.seconds = 25 * minute - 1
        controller.tick()
        let shown = try #require(model.snapshot)
        #expect(shown.displaySeconds == 1)

        // Focus 1 runs out before the click on "Skip to Break" lands.
        clock.seconds = 25 * minute + 0.5
        model.skipPhase(shown: shown)
        let afterSkip = try #require(model.snapshot)
        #expect(afterSkip.kind == .shortBreak && afterSkip.round == 1)

        model.pause()
        #expect(model.snapshot?.isPaused == true)
        model.resume()
        #expect(model.snapshot?.isPaused == false)
        model.skipPhase(shown: afterSkip)
        #expect(model.snapshot?.kind == .focus && model.snapshot?.round == 2)
        model.cancel()
        #expect(model.snapshot == nil)
    }
}

/// Set from an observation callback, which Swift 6 requires to be `Sendable`.
private final class Flag: @unchecked Sendable {
    var isSet = false
}

@MainActor
private final class PanelTestClock {
    var seconds: TimeInterval = 0
    var now: TimerInstant { TimerInstant(monotonic: 50_000 + seconds, wall: 1_800_000_000 + seconds) }
}

/// Renders the Timer section offscreen to PNGs for eyeballing layout. Only runs when
/// OPENGLOW_SNAPSHOT_DIR is set: `OPENGLOW_SNAPSHOT_DIR=/tmp/shots ./Scripts/test.sh --filter TimerPanelSnapshot`.
@Suite("Timer panel snapshots")
@MainActor
struct TimerPanelSnapshotTests {
    nonisolated private static let outputDirectory = ProcessInfo.processInfo.environment["OPENGLOW_SNAPSHOT_DIR"]

    @Test(.enabled(if: outputDirectory != nil))
    func renderPanelStates() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let noActions = TimerMenu.Actions(
            startCountdown: { _ in }, startPomodoro: { _ in }, pause: {}, resume: {},
            skipPhase: { _, _ in }, cancel: {}, askForCustomMinutes: { nil }
        )
        let states: [(String, TimerSnapshot?)] = [
            ("idle", nil),
            ("countdown", TimerSnapshot(kind: .countdown, remaining: 671, duration: 900, round: nil, rounds: nil, isPaused: false, isLastPhase: true)),
            ("focus", TimerSnapshot(kind: .focus, remaining: 1_453, duration: 1_500, round: 2, rounds: 4, isPaused: false, isLastPhase: false)),
            ("break-paused", TimerSnapshot(kind: .shortBreak, remaining: 190, duration: 300, round: 2, rounds: 4, isPaused: true, isLastPhase: false)),
            ("long-break", TimerSnapshot(kind: .longBreak, remaining: 600, duration: 900, round: 4, rounds: 4, isPaused: false, isLastPhase: true)),
        ]
        for (name, snapshot) in states {
            let model = TimerPanelModel(actions: noActions)
            model.snapshot = snapshot
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                // Laid out as the popover would: its width, padding and small controls.
                let view = TimerPanel(model: model)
                    .controlSize(.small)
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("timer-\(name)-\(suffix).png"))
            }
        }
    }
}
