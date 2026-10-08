import AppKit
import Foundation
import Testing
@testable import OpenGlow

/// Builds instants on both clocks moving together, as they do while the Mac is awake or asleep.
private func instant(_ seconds: TimeInterval, wallOffset: TimeInterval = 0) -> TimerInstant {
    TimerInstant(monotonic: 50_000 + seconds, wall: 1_800_000_000 + seconds + wallOffset)
}

private let minute: TimeInterval = 60

@Suite("Glow timer: countdown")
struct CountdownTests {
    @Test func countsDownFromTheInjectedClock() throws {
        let timer = GlowTimer.countdown(5 * minute, startingAt: instant(0))
        let start = try #require(timer.snapshot(at: instant(0)))
        #expect(start.kind == .countdown && start.remaining == 300 && start.remainingFraction == 1)
        #expect(start.displaySeconds == 300 && start.round == nil && start.rounds == nil && !start.isPaused)
        #expect(start.isLastPhase)
        // The display rounds up: 5:00 for the first second, 4:59 once a full second has gone.
        #expect(timer.snapshot(at: instant(0.4))?.displaySeconds == 300)
        #expect(timer.snapshot(at: instant(1))?.displaySeconds == 299)
        #expect(timer.remainingFraction(at: instant(150)) == 0.5)
        #expect(timer.snapshot(at: instant(299.5))?.displaySeconds == 1)
        #expect(timer.snapshot(at: instant(300)) == nil)
    }

    @Test func endsOnceAndStaysOver() {
        var timer = GlowTimer.countdown(minute, startingAt: instant(0))
        #expect(timer.advance(to: instant(59.9)).isEmpty)
        let ended = timer.advance(to: instant(60))
        #expect(ended.map(\.kind) == [.countdown])
        #expect(timer.isOver && timer.remaining(at: instant(60)) == 0)
        #expect(timer.advance(to: instant(600)).isEmpty)
    }

    @Test func pauseFreezesAndResumeContinues() {
        var timer = GlowTimer.countdown(5 * minute, startingAt: instant(0))
        timer.pause(at: instant(100))
        #expect(timer.isPaused && timer.remaining(at: instant(1_000)) == 200)
        #expect(timer.secondsUntilNextTick(at: instant(1_000)) == nil)
        timer.pause(at: instant(2_000))  // Already paused: no change.
        #expect(timer.remaining(at: instant(2_000)) == 200)
        timer.resume(at: instant(2_000))
        #expect(!timer.isPaused && timer.remaining(at: instant(2_050)) == 150)
        timer.resume(at: instant(2_060))  // Already running: no change.
        #expect(timer.remaining(at: instant(2_100)) == 100)
        #expect(timer.snapshot(at: instant(2_200)) == nil)
    }

    @Test func pausedSnapshotSaysSo() {
        var timer = GlowTimer.countdown(minute, startingAt: instant(0))
        timer.pause(at: instant(10))
        #expect(timer.snapshot(at: instant(500))?.isPaused == true)
        #expect(timer.snapshot(at: instant(500))?.remaining == 50)
    }

    @Test func cancelEndsTheTimer() {
        var timer = GlowTimer.countdown(minute, startingAt: instant(0))
        timer.cancel()
        #expect(timer.isOver && timer.snapshot(at: instant(1)) == nil)
        timer.resume(at: instant(2))
        #expect(timer.isOver)
    }

    @Test func durationsAreClamped() {
        let tiny = GlowTimer.countdown(0, startingAt: instant(0))
        #expect(tiny.phase.duration == GlowTimerConfig.minimumDuration)
        let huge = GlowTimer.countdown(1e9, startingAt: instant(0))
        #expect(huge.phase.duration == GlowTimerConfig.maximumDuration)
        let invalid = GlowTimer.countdown(.nan, startingAt: instant(0))
        #expect(invalid.phase.duration == GlowTimerConfig.minimumDuration)
    }

    @Test func ticksLandOnSecondBoundariesAndTheEnd() throws {
        let timer = GlowTimer.countdown(5 * minute, startingAt: instant(0))
        #expect(timer.secondsUntilNextTick(at: instant(0)) == 1)
        let fromMidSecond = try #require(timer.secondsUntilNextTick(at: instant(0.25)))
        #expect(abs(fromMidSecond - 0.75) < 1e-9)
        let fromLastHalfSecond = try #require(timer.secondsUntilNextTick(at: instant(299.5)))
        #expect(abs(fromLastHalfSecond - 0.5) < 1e-9)
        #expect(timer.secondsUntilNextTick(at: instant(301)) == 0)
    }
}

@Suite("Glow timer: Pomodoro")
struct PomodoroTests {
    @Test func runsFourRoundsThenTheLongBreak() {
        var timer = GlowTimer.pomodoro(startingAt: instant(0))
        var clock: TimeInterval = 0
        var phases: [TimerPhase] = []
        while !timer.isOver {
            phases.append(timer.phase)
            clock += timer.phase.duration
            timer.advance(to: instant(clock))
        }
        #expect(phases.map(\.kind) == [.focus, .shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak])
        #expect(phases.map(\.round) == [1, 1, 2, 2, 3, 3, 4, 4])
        #expect(phases.map(\.duration) == [25, 5, 25, 5, 25, 5, 25, 15].map { $0 * minute })
        #expect(clock == 130 * minute)
    }

    @Test func snapshotsShowRoundOfRounds() throws {
        let timer = GlowTimer.pomodoro(startingAt: instant(0))
        let secondRound = try #require(timer.snapshot(at: instant(31 * minute)))
        #expect(secondRound.kind == .focus && secondRound.round == 2 && secondRound.rounds == 4)
        #expect(secondRound.remaining == 24 * minute)
        let shortBreak = try #require(timer.snapshot(at: instant(26 * minute)))
        #expect(shortBreak.kind == .shortBreak && shortBreak.round == 1 && shortBreak.remaining == 4 * minute)
    }

    @Test func repeatingPlanStartsANewSet() {
        let plan = PomodoroPlan(focus: 10, shortBreak: 2, longBreak: 5, roundsPerSet: 2, repeats: true)
        var timer = GlowTimer.pomodoro(plan, startingAt: instant(0))
        let ended = timer.advance(to: instant(10 + 2 + 10 + 5))
        #expect(ended.map(\.kind) == [.focus, .shortBreak, .focus, .longBreak])
        #expect(!timer.isOver && timer.phase.kind == .focus && timer.phase.round == 1)
    }

    @Test func onlyTheLongBreakIsTheLastPhase() throws {
        let timer = GlowTimer.pomodoro(startingAt: instant(0))
        // Focus 1, its short break, and focus 4 are not last; the long break that ends the set is.
        for minutes in [1.0, 26, 106] {
            #expect(timer.snapshot(at: instant(minutes * minute))?.isLastPhase == false)
        }
        let longBreak = try #require(timer.snapshot(at: instant(121 * minute)))
        #expect(longBreak.kind == .longBreak && longBreak.isLastPhase)
        #expect(timer.snapshot(ofEnded: TimerPhase(kind: .longBreak, duration: 15 * minute, round: 4)).isLastPhase)
        #expect(!timer.snapshot(ofEnded: TimerPhase(kind: .focus, duration: 25 * minute, round: 4)).isLastPhase)
    }

    @Test func aRepeatingPlanHasNoLastPhase() throws {
        let plan = PomodoroPlan(focus: 10, shortBreak: 2, longBreak: 5, roundsPerSet: 1, repeats: true)
        let timer = GlowTimer.pomodoro(plan, startingAt: instant(0))
        let longBreak = try #require(timer.snapshot(at: instant(11)))
        #expect(longBreak.kind == .longBreak && !longBreak.isLastPhase)
    }

    @Test func skipStartsTheNextPhaseInFull() {
        var timer = GlowTimer.pomodoro(startingAt: instant(0))
        timer.skipPhase(at: instant(10 * minute))
        #expect(timer.phase.kind == .shortBreak && timer.remaining(at: instant(10 * minute)) == 5 * minute)
        // Skipping while paused starts the next phase running.
        timer.pause(at: instant(11 * minute))
        timer.skipPhase(at: instant(20 * minute))
        #expect(timer.phase.kind == .focus && timer.phase.round == 2 && !timer.isPaused)
        #expect(timer.remaining(at: instant(21 * minute)) == 24 * minute)
    }

    @Test func skippingTheLastPhaseEndsTheSession() {
        let plan = PomodoroPlan(focus: 10, shortBreak: 2, longBreak: 5, roundsPerSet: 1, repeats: false)
        var timer = GlowTimer.pomodoro(plan, startingAt: instant(0))
        timer.skipPhase(at: instant(1))
        #expect(timer.phase.kind == .longBreak)
        timer.skipPhase(at: instant(2))
        #expect(timer.isOver)
    }

    @Test func overshootCarriesIntoTheNextPhase() {
        var timer = GlowTimer.pomodoro(startingAt: instant(0))
        let ended = timer.advance(to: instant(25 * minute + 30))
        #expect(ended.map(\.kind) == [.focus])
        #expect(timer.phase.kind == .shortBreak && timer.remaining(at: instant(25 * minute + 30)) == 4 * minute + 30)
    }

    @Test func planClampsNonsense() {
        let plan = PomodoroPlan(focus: -5, shortBreak: 0, longBreak: 1e12, roundsPerSet: 0, repeats: false)
        #expect(plan.focus == GlowTimerConfig.minimumDuration && plan.longBreak == GlowTimerConfig.maximumDuration)
        #expect(plan.roundsPerSet == 1)
    }
}

@Suite("Glow timer: sleep and clock changes")
struct TimerClockTests {
    @Test func sleepCountsAgainstTheTimer() {
        // Lid closed for 10 minutes: both clocks move on by 600 s between readings.
        let timer = GlowTimer.countdown(25 * minute, startingAt: instant(0))
        #expect(timer.remaining(at: instant(5 * minute + 600)) == 10 * minute)
    }

    @Test func sleepAcrossPhaseEndsLandsInTheRightPhase() {
        // Asleep from minute 0 to 40: focus (25) and the short break (5) both ended meanwhile.
        var timer = GlowTimer.pomodoro(startingAt: instant(0))
        let ended = timer.advance(to: instant(40 * minute))
        #expect(ended.map(\.kind) == [.focus, .shortBreak])
        #expect(timer.phase.kind == .focus && timer.phase.round == 2)
        #expect(timer.remaining(at: instant(40 * minute)) == 15 * minute)
    }

    @Test func wallClockChangesDoNotMoveTheTimer() {
        let timer = GlowTimer.countdown(10 * minute, startingAt: instant(0))
        // Ten seconds pass while the user sets the clock back an hour, or NTP steps it forward.
        #expect(timer.remaining(at: instant(10, wallOffset: -3_600)) == 590)
        #expect(timer.remaining(at: instant(10, wallOffset: 3_600)) == 590)
    }

    @Test func aMonotonicRestartFallsBackToTheWallClock() {
        let earlier = TimerInstant(monotonic: 90_000, wall: 1_800_000_000)
        let afterRestart = TimerInstant(monotonic: 30, wall: 1_800_000_120)
        #expect(afterRestart.seconds(since: earlier) == 120)
        let wallBackwardsToo = TimerInstant(monotonic: 30, wall: 1_799_999_000)
        #expect(wallBackwardsToo.seconds(since: earlier) == 0)
    }

    @Test func liveClockMovesForward() {
        let first = TimerInstant.now()
        let second = TimerInstant.now()
        #expect(second.seconds(since: first) >= 0)
        #expect(second.monotonic > 0 && second.wall > 1_700_000_000)
    }
}

/// A clock tests move by hand.
@MainActor
private final class TestClock {
    var seconds: TimeInterval = 0
    var now: TimerInstant { instant(seconds) }
}

@Suite("Timer controller")
@MainActor
struct TimerControllerTests {
    private let clock = TestClock()

    private func makeController(sounds: @escaping () -> Void = {}) -> TimerController {
        let clock = clock
        return TimerController(clock: { clock.now }, playSound: sounds)
    }

    @Test func publishesStartTicksAndTheEnd() throws {
        var updates: [TimerSnapshot?] = []
        var finished: [TimerSnapshot] = []
        var sounds = 0
        let controller = makeController { sounds += 1 }
        controller.onUpdate = { updates.append($0) }
        controller.onPhaseFinished = { finished.append($0) }

        controller.startCountdown(minute)
        #expect(updates.count == 1 && updates.last??.remaining == 60)
        clock.seconds = 30
        controller.tick()
        #expect(updates.last??.displaySeconds == 30)
        #expect(finished.isEmpty && sounds == 0)

        clock.seconds = 60
        controller.tick()
        let ended = try #require(finished.first)
        #expect(finished.count == 1 && ended.kind == .countdown && ended.remaining == 0 && ended.remainingFraction == 0)
        #expect(sounds == 1)
        #expect(updates.last! == nil && controller.timer == nil && controller.snapshot == nil)

        controller.tick()  // Nothing left to do.
        #expect(finished.count == 1)
    }

    @Test func pauseResumeSkipAndCancelPublish() {
        var updates: [TimerSnapshot?] = []
        let controller = makeController()
        controller.onUpdate = { updates.append($0) }

        controller.startPomodoro()
        clock.seconds = 60
        controller.togglePause()
        #expect(updates.last??.isPaused == true && updates.last??.remaining == 24 * minute)
        clock.seconds = 600
        controller.togglePause()
        #expect(updates.last??.isPaused == false && updates.last??.remaining == 24 * minute)
        controller.skipPhase(expecting: .focus, round: 1)
        #expect(updates.last??.kind == .shortBreak && updates.last??.remaining == 5 * minute)
        controller.cancel()
        #expect(updates.last! == nil && controller.snapshot == nil)
        let count = updates.count
        controller.pause()
        #expect(updates.count == count)
    }

    @Test func phasesEndedInOneSleepReportOnce() {
        var finished: [TimerSnapshot] = []
        var sounds = 0
        let controller = makeController { sounds += 1 }
        controller.onPhaseFinished = { finished.append($0) }
        controller.startPomodoro()
        clock.seconds = 31 * minute  // Asleep through focus and the short break.
        controller.tick()
        #expect(finished.map(\.kind) == [.shortBreak] && sounds == 1)
        #expect(controller.snapshot?.kind == .focus && controller.snapshot?.round == 2)
    }

    @Test func aPauseRacingThePhaseEndStillReportsIt() {
        var finished: [TimerSnapshot] = []
        let controller = makeController()
        controller.onPhaseFinished = { finished.append($0) }
        controller.startPomodoro()
        clock.seconds = 25 * minute + 1
        controller.pause()
        #expect(finished.map(\.kind) == [.focus])
        #expect(controller.snapshot?.kind == .shortBreak && controller.snapshot?.isPaused == true)
    }

    @Test func aSkipRacingThePhaseEndKeepsTheBreak() throws {
        // The menu was built with focus 1 a second from its end; the click lands just after it.
        var finished: [TimerSnapshot] = []
        let controller = makeController()
        controller.onPhaseFinished = { finished.append($0) }
        controller.startPomodoro()
        clock.seconds = 25 * minute - 1
        let shown = try #require(controller.snapshot)
        clock.seconds = 25 * minute + 0.5
        controller.skipPhase(expecting: shown.kind, round: shown.round)
        #expect(finished.map(\.kind) == [.focus])
        let now = try #require(controller.snapshot)
        #expect(now.kind == .shortBreak && now.round == 1 && now.remaining == 5 * minute - 0.5)
    }

    @Test func skippingTheShownPhaseStillWorksMidPhase() throws {
        let controller = makeController()
        controller.startPomodoro()
        clock.seconds = 28 * minute  // In the short break after round 1.
        controller.skipPhase(expecting: .focus, round: 1)  // Stale: nothing happens.
        #expect(controller.snapshot?.kind == .shortBreak)
        controller.skipPhase(expecting: .shortBreak, round: 2)  // Wrong round: nothing either.
        #expect(controller.snapshot?.kind == .shortBreak)
        controller.skipPhase(expecting: .shortBreak, round: 1)
        let focus = try #require(controller.snapshot)
        #expect(focus.kind == .focus && focus.round == 2 && focus.remaining == 25 * minute)
    }

    @Test func finishingThePomodoroOnItsLastPhaseEndsIt() {
        var updates: [TimerSnapshot?] = []
        let controller = makeController()
        controller.onUpdate = { updates.append($0) }
        controller.startPomodoro()
        clock.seconds = 121 * minute
        controller.tick()
        #expect(updates.last??.kind == .longBreak && updates.last??.isLastPhase == true)
        controller.skipPhase(expecting: .longBreak, round: 4)
        #expect(updates.last! == nil && controller.snapshot == nil)
    }

    @Test func startingAgainReplacesTheTimer() {
        let controller = makeController()
        controller.startPomodoro()
        controller.startCountdown(10 * minute)
        #expect(controller.snapshot?.kind == .countdown && controller.isPomodoro == false)
    }
}

@Suite("Timer menu")
@MainActor
struct TimerMenuTests {
    private final class Log {
        var calls: [String] = []
    }

    private func actions(_ log: Log, customMinutes: Int? = 20) -> TimerMenu.Actions {
        TimerMenu.Actions(
            startCountdown: { log.calls.append("countdown \(Int($0))") },
            startPomodoro: { log.calls.append("pomodoro \(Int($0.focus / 60))/\(Int($0.shortBreak / 60))") },
            pause: { log.calls.append("pause") },
            resume: { log.calls.append("resume") },
            skipPhase: { log.calls.append("skip \($0) \($1.map(String.init) ?? "-")") },
            cancel: { log.calls.append("cancel") },
            askForCustomMinutes: { customMinutes }
        )
    }

    private func snapshot(_ kind: TimerKind, remaining: TimeInterval = 299, paused: Bool = false, round: Int = 2) -> TimerSnapshot {
        let pomodoro = kind != .countdown
        return TimerSnapshot(
            kind: kind,
            remaining: remaining,
            duration: 300,
            round: pomodoro ? round : nil,
            rounds: pomodoro ? 4 : nil,
            isPaused: paused,
            isLastPhase: kind == .countdown || kind == .longBreak
        )
    }

    private func titles(_ item: NSMenuItem) -> [String] {
        item.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
    }

    @Test func idleMenuOffersPresetsCustomAndPomodoro() throws {
        _ = NSApplication.shared
        let log = Log()
        let item = TimerMenu.makeItem(for: nil, actions: actions(log))
        #expect(item.title == "Timer")
        #expect(titles(item) == ["5 Minutes", "10 Minutes", "15 Minutes", "25 Minutes", "45 Minutes", "1 Hour", "Custom…", "—", "Start Pomodoro (25/5)"])
        let menu = try #require(item.submenu)
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 5)
        menu.performActionForItem(at: 6)
        menu.performActionForItem(at: 8)
        #expect(log.calls == ["countdown 300", "countdown 3600", "countdown 1200", "pomodoro 25/5"])
    }

    @Test func pomodoroItemStartsThePlanItNames() throws {
        _ = NSApplication.shared
        let log = Log()
        let plan = PomodoroPlan(focus: 50 * minute, shortBreak: 10 * minute, longBreak: 30 * minute, roundsPerSet: 3, repeats: false)
        let item = TimerMenu.makeItem(for: nil, plan: plan, actions: actions(log))
        #expect(titles(item).last == "Start Pomodoro (50/10)")
        try #require(item.submenu).performActionForItem(at: 8)
        #expect(log.calls == ["pomodoro 50/10"])
    }

    @Test func cancellingCustomStartsNothing() throws {
        _ = NSApplication.shared
        let log = Log()
        let menu = try #require(TimerMenu.makeItem(for: nil, actions: actions(log, customMinutes: nil)).submenu)
        menu.performActionForItem(at: 6)
        #expect(log.calls.isEmpty)
    }

    @Test func runningCountdownMenu() throws {
        _ = NSApplication.shared
        let log = Log()
        let item = TimerMenu.makeItem(for: snapshot(.countdown), actions: actions(log))
        #expect(titles(item) == ["Timer — 4:59 left", "—", "Pause", "Cancel Timer"])
        let menu = try #require(item.submenu)
        #expect(menu.items[0].isEnabled == false)
        menu.performActionForItem(at: 2)
        menu.performActionForItem(at: 3)
        #expect(log.calls == ["pause", "cancel"])
    }

    @Test func runningAndPausedPomodoroMenus() throws {
        _ = NSApplication.shared
        let log = Log()
        let focus = TimerMenu.makeItem(for: snapshot(.focus, remaining: 1453), actions: actions(log))
        #expect(titles(focus) == ["Focus 2 of 4 — 24:13 left", "—", "Pause", "Skip to Break", "Cancel Timer"])
        let paused = TimerMenu.makeItem(for: snapshot(.shortBreak, paused: true), actions: actions(log))
        #expect(titles(paused) == ["Short Break — paused at 4:59", "—", "Resume", "Skip Break", "Cancel Timer"])
        let menu = try #require(paused.submenu)
        menu.performActionForItem(at: 2)
        menu.performActionForItem(at: 3)
        // The skip item carries the phase it was built for.
        #expect(log.calls == ["resume", "skip shortBreak 2"])
    }

    @Test func theLastPhaseOffersFinishPomodoro() throws {
        _ = NSApplication.shared
        let log = Log()
        let item = TimerMenu.makeItem(for: snapshot(.longBreak, round: 4), actions: actions(log))
        #expect(titles(item) == ["Long Break — 4:59 left", "—", "Pause", "Finish Pomodoro", "Cancel Timer"])
        try #require(item.submenu).performActionForItem(at: 3)
        #expect(log.calls == ["skip longBreak 4"])
        #expect(TimerMenu.skipTitle(for: snapshot(.countdown)) == nil)
        #expect(TimerMenu.skipTitle(for: snapshot(.focus)) == "Skip to Break")
        #expect(TimerMenu.skipTitle(for: snapshot(.shortBreak)) == "Skip Break")
    }

    @Test func aSkipItemLeftOpenPastThePhaseEndKeepsTheBreak() throws {
        _ = NSApplication.shared
        let clock = TestClock()
        let controller = TimerController(clock: { clock.now }, playSound: {})
        controller.startPomodoro()
        clock.seconds = 25 * minute - 3
        let item = TimerMenu.makeItem(for: controller.snapshot, actions: TimerMenu.Actions(controller: controller))
        #expect(titles(item)[3] == "Skip to Break")
        clock.seconds = 25 * minute + 0.5  // The menu is still open as focus 1 runs out.
        try #require(item.submenu).performActionForItem(at: 3)
        #expect(controller.snapshot?.kind == .shortBreak && controller.snapshot?.round == 1)
    }

    @Test func presetTitles() {
        #expect(TimerMenu.presetTitle(minutes: 1) == "1 Minute")
        #expect(TimerMenu.presetTitle(minutes: 90) == "90 Minutes")
        #expect(TimerMenu.presetTitle(minutes: 120) == "2 Hours")
    }

    @Test(arguments: [
        (0, "0:00"), (59, "0:59"), (299, "4:59"), (1_440, "24:00"), (3_600, "1:00:00"), (3_723, "1:02:03"), (-5, "0:00"),
    ])
    func clockStrings(seconds: Int, expected: String) {
        #expect(TimerMenu.clockString(seconds: seconds) == expected)
    }

    @Test func statusTitleUsesMonospacedDigits() throws {
        let narrow = TimerMenu.statusTitle(for: snapshot(.countdown, remaining: 671))  // "11:11"
        let wide = TimerMenu.statusTitle(for: snapshot(.countdown, remaining: 2_888))  // "48:08"
        #expect(narrow.string == "11:11" && wide.string == "48:08")
        // Equal widths: the countdown doesn't jitter as digits change.
        #expect(abs(narrow.size().width - wide.size().width) < 0.01)
        let font = try #require(narrow.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == NSFont.menuBarFont(ofSize: 0).pointSize)
    }

    @Test func statusGlyphsResolve() {
        for kind in [TimerKind.countdown, .focus, .shortBreak, .longBreak] {
            #expect(TimerMenu.statusImage(for: snapshot(kind)) != nil)
            #expect(TimerMenu.statusImage(for: snapshot(kind, paused: true)) != nil)
        }
        #expect(TimerMenu.statusDescription(for: snapshot(.focus)) == "Open Glow — Focus 2 of 4 — 4:59 left")
    }

    @Test func attentionTakesTheGlyphAndJoinsTheTooltip() {
        let warning = TimerAttention(symbol: "exclamationmark.triangle", description: "Open Glow can't capture audio for Music Sync")
        #expect(TimerMenu.statusDescription(for: snapshot(.focus), attention: warning)
            == "Open Glow — Focus 2 of 4 — 4:59 left\nOpen Glow can't capture audio for Music Sync")
        #expect(TimerMenu.statusImage(for: snapshot(.focus, paused: true), attention: warning) != nil)
        // The glyph comes from the attention's symbol, not the phase's: an unknown one draws nothing.
        let unknown = TimerAttention(symbol: "no.such.symbol", description: "x")
        #expect(TimerMenu.statusImage(for: snapshot(.focus), attention: unknown) == nil)

        let button = NSButton(title: "", target: nil, action: nil)
        TimerMenu.showCountdown(snapshot(.focus), attention: warning, on: button)
        #expect(button.title == "4:59" && button.image != nil)
        #expect(button.toolTip == TimerMenu.statusDescription(for: snapshot(.focus), attention: warning))
        #expect(button.image?.accessibilityDescription == button.toolTip)
        TimerMenu.showCountdown(snapshot(.focus), on: button)
        #expect(button.toolTip == "Open Glow — Focus 2 of 4 — 4:59 left")
    }

    @Test func countdownReplacesAndRestoresTheButton() {
        let button = NSButton(title: "", target: nil, action: nil)
        TimerMenu.showCountdown(snapshot(.focus), on: button)
        #expect(button.title == "4:59" && button.image != nil && button.imagePosition == .imageLeading)
        TimerMenu.hideCountdown(on: button)
        #expect(button.title.isEmpty && button.imagePosition == .imageOnly)
    }

    @Test(arguments: [
        ("20", 20), (" 45 ", 45), ("1:30", 90), ("0:05", 5), ("24:00", 1_440), ("1440", 1_440),
        ("0", nil), ("1441", nil), ("-5", nil), ("1:5", nil), ("1:60", nil), ("abc", nil), ("", nil),
        ("2.5", nil), ("1:30:00", nil), ("٣", nil), ("99999999999", nil),
    ] as [(String, Int?)])
    func customMinutesParse(text: String, expected: Int?) {
        #expect(TimerMenu.parseMinutes(text) == expected)
    }
}
