import Foundation

/// Pomodoro defaults.
enum PomodoroConfig {
    /// Minutes of focus per round. Sane range: 10–60.
    static let focusMinutes: Double = 25
    /// Minutes of the break after each focus round but the last of a set. Sane range: 2–15.
    static let shortBreakMinutes: Double = 5
    /// Minutes of the break after the last focus round of a set. Sane range: 10–30.
    static let longBreakMinutes: Double = 15
    /// Focus rounds per set; the long break follows the last one. Sane range: 2–8.
    static let roundsPerSet = 4
    /// Whether a new set starts after the long break. When false the session ends there, so a
    /// Pomodoro left running overnight doesn't cycle until morning.
    static let repeatsAfterLongBreak = false
}

/// Limits for any timer phase.
enum GlowTimerConfig {
    /// Shortest phase, in seconds. Sane range: 1–60.
    static let minimumDuration: TimeInterval = 1
    /// Longest phase, in seconds. Sane range: 1–24 hours.
    static let maximumDuration: TimeInterval = 24 * 60 * 60

    static func clampedDuration(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return minimumDuration }
        return min(max(seconds, minimumDuration), maximumDuration)
    }
}

/// A moment, read from two clocks at once.
///
/// Elapsed time comes from the continuous monotonic clock (`CLOCK_MONOTONIC_RAW`, which is
/// `mach_continuous_time` and what Swift's `ContinuousClock` reads). It keeps counting while the
/// Mac sleeps, so a laptop closed for 10 minutes comes back 10 minutes further on, and it never
/// jumps when the user or NTP sets the wall clock. The uptime clocks (`systemUptime`,
/// `DispatchTime`, `CLOCK_UPTIME_RAW`) stop during sleep and would freeze the timer; the wall
/// clock alone would move the timer by every clock change.
///
/// The wall clock is recorded alongside as the fallback for readings the monotonic clock can't
/// compare: it restarts at boot, so a later reading below an earlier one means a restart sat in
/// between. Within one launch that can't happen; a timer that is ever persisted across launches
/// should also compare boot sessions (`kern.bootsessionuuid`), since a post-reboot reading can
/// be larger than a pre-reboot one too.
struct TimerInstant: Equatable, Sendable {
    /// Seconds on the continuous monotonic clock, from an arbitrary origin at boot.
    var monotonic: TimeInterval
    /// Seconds since 1970 on the wall clock.
    var wall: TimeInterval

    static func now() -> TimerInstant {
        TimerInstant(
            monotonic: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
            wall: Date().timeIntervalSince1970
        )
    }

    /// Seconds from `earlier` to this instant, never negative.
    func seconds(since earlier: TimerInstant) -> TimeInterval {
        let monotonicDelta = monotonic - earlier.monotonic
        if monotonicDelta >= 0 { return monotonicDelta }
        return max(0, wall - earlier.wall)
    }
}

/// What a timer phase is.
enum TimerKind: Equatable, Sendable {
    case countdown
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self == .shortBreak || self == .longBreak }
}

/// One stretch of a timer: a whole countdown, or one Pomodoro focus round or break.
struct TimerPhase: Equatable, Sendable {
    var kind: TimerKind
    /// Seconds.
    var duration: TimeInterval
    /// The Pomodoro round, 1-based; a break carries the number of the round it follows. Nil for
    /// a countdown.
    var round: Int?
}

/// The shape of a Pomodoro session.
struct PomodoroPlan: Equatable, Sendable {
    /// Seconds per focus round, short break and long break.
    let focus: TimeInterval
    let shortBreak: TimeInterval
    let longBreak: TimeInterval
    let roundsPerSet: Int
    let repeats: Bool

    init(focus: TimeInterval, shortBreak: TimeInterval, longBreak: TimeInterval, roundsPerSet: Int, repeats: Bool) {
        self.focus = GlowTimerConfig.clampedDuration(focus)
        self.shortBreak = GlowTimerConfig.clampedDuration(shortBreak)
        self.longBreak = GlowTimerConfig.clampedDuration(longBreak)
        self.roundsPerSet = max(1, roundsPerSet)
        self.repeats = repeats
    }

    static let standard = PomodoroPlan(
        focus: PomodoroConfig.focusMinutes * 60,
        shortBreak: PomodoroConfig.shortBreakMinutes * 60,
        longBreak: PomodoroConfig.longBreakMinutes * 60,
        roundsPerSet: PomodoroConfig.roundsPerSet,
        repeats: PomodoroConfig.repeatsAfterLongBreak
    )

    var firstPhase: TimerPhase { focusPhase(round: 1) }

    /// The phase that follows `phase`, or nil when the session ends with it.
    func phase(after phase: TimerPhase) -> TimerPhase? {
        let round = phase.round ?? 1
        switch phase.kind {
        case .focus:
            return round < roundsPerSet
                ? TimerPhase(kind: .shortBreak, duration: shortBreak, round: round)
                : TimerPhase(kind: .longBreak, duration: longBreak, round: round)
        case .shortBreak:
            return focusPhase(round: round + 1)
        case .longBreak:
            return repeats ? firstPhase : nil
        case .countdown:
            return nil
        }
    }

    private func focusPhase(round: Int) -> TimerPhase {
        TimerPhase(kind: .focus, duration: focus, round: round)
    }
}

/// A timer's state at one instant, as the menu bar, the menu and the edge light show it.
struct TimerSnapshot: Equatable, Sendable {
    var kind: TimerKind
    /// Seconds left in the current phase, 0...`duration`.
    var remaining: TimeInterval
    /// Length of the current phase, in seconds.
    var duration: TimeInterval
    /// "Round x of y" for Pomodoro; nil for a countdown.
    var round: Int?
    var rounds: Int?
    var isPaused: Bool

    /// Share of the phase still to go: 1 at the start, 0 at the end.
    var remainingFraction: Double {
        duration > 0 ? min(max(remaining / duration, 0), 1) : 0
    }

    /// Whole seconds as displayed. Rounded up, so a 5-minute timer reads 5:00 for its first
    /// second and 0:00 exactly when it ends.
    var displaySeconds: Int {
        max(0, Int(remaining.rounded(.up)))
    }
}

/// A countdown or a Pomodoro session, as a value: every change takes the instant it happens at,
/// so the model is exact for any clock and tests never sleep.
///
/// Running time accrues per phase: `bankedElapsed` holds what ran before the last pause (or
/// what spilled over from the previous phase), plus the time since `runningSince` while running.
struct GlowTimer: Equatable, Sendable {
    enum Program: Equatable, Sendable {
        case countdown(TimeInterval)
        case pomodoro(PomodoroPlan)
    }

    let program: Program
    private(set) var phase: TimerPhase
    private(set) var isPaused = false
    /// True once the last phase has ended or the timer was cancelled. Nothing changes after that.
    private(set) var isOver = false
    private var bankedElapsed: TimeInterval = 0
    /// When the current phase last started running; nil while paused or over.
    private var runningSince: TimerInstant?

    init(_ program: Program, startingAt now: TimerInstant) {
        self.program = program
        switch program {
        case .countdown(let duration):
            phase = TimerPhase(kind: .countdown, duration: GlowTimerConfig.clampedDuration(duration), round: nil)
        case .pomodoro(let plan):
            phase = plan.firstPhase
        }
        runningSince = now
    }

    static func countdown(_ duration: TimeInterval, startingAt now: TimerInstant) -> GlowTimer {
        GlowTimer(.countdown(duration), startingAt: now)
    }

    static func pomodoro(_ plan: PomodoroPlan = .standard, startingAt now: TimerInstant) -> GlowTimer {
        GlowTimer(.pomodoro(plan), startingAt: now)
    }

    var isPomodoro: Bool {
        if case .pomodoro = program { return true }
        return false
    }

    /// Focus rounds per set, for "round x of y"; nil for a countdown.
    var rounds: Int? {
        if case .pomodoro(let plan) = program { return plan.roundsPerSet }
        return nil
    }

    // MARK: Reading

    /// Running time in the current phase at `now`. Can exceed the phase's duration until
    /// `advance(to:)` moves on.
    func elapsed(at now: TimerInstant) -> TimeInterval {
        bankedElapsed + (runningSince.map { now.seconds(since: $0) } ?? 0)
    }

    /// Seconds left in the current phase at `now`, 0...duration. Doesn't move to later phases;
    /// `snapshot(at:)` does.
    func remaining(at now: TimerInstant) -> TimeInterval {
        guard !isOver else { return 0 }
        return min(max(phase.duration - elapsed(at: now), 0), phase.duration)
    }

    /// `remaining(at:)` as a share of the phase: 1 at the start, 0 at the end.
    func remainingFraction(at now: TimerInstant) -> Double {
        remaining(at: now) / phase.duration
    }

    /// The state at `now`, including any phases that have ended by then; nil once over.
    func snapshot(at now: TimerInstant) -> TimerSnapshot? {
        var current = self
        current.advance(to: now)
        guard !current.isOver else { return nil }
        return TimerSnapshot(
            kind: current.phase.kind,
            remaining: current.remaining(at: now),
            duration: current.phase.duration,
            round: current.phase.round,
            rounds: rounds,
            isPaused: current.isPaused
        )
    }

    /// How a phase that just ended reads: nothing left.
    func snapshot(ofEnded phase: TimerPhase) -> TimerSnapshot {
        TimerSnapshot(kind: phase.kind, remaining: 0, duration: phase.duration, round: phase.round, rounds: rounds, isPaused: false)
    }

    /// Seconds from `now` until the displayed second changes or the phase ends, whichever is
    /// first; nil while paused or over, when nothing changes. Call `advance(to:)` first.
    func secondsUntilNextTick(at now: TimerInstant) -> TimeInterval? {
        guard !isOver, !isPaused else { return nil }
        let left = phase.duration - elapsed(at: now)
        guard left > 0 else { return 0 }
        // The display rounds up, so it changes when `left` reaches the whole second below.
        return left - (left.rounded(.up) - 1)
    }

    // MARK: Changing

    /// Moves past every phase that has ended by `now`, carrying the overshoot into the next one
    /// (so time spent asleep counts against the phases it covered), and returns the ended phases
    /// in order.
    @discardableResult
    mutating func advance(to now: TimerInstant) -> [TimerPhase] {
        var ended: [TimerPhase] = []
        while !isOver {
            let elapsed = elapsed(at: now)
            guard elapsed >= phase.duration else { break }
            ended.append(phase)
            enterPhase(after: phase, carrying: elapsed - phase.duration, at: now)
        }
        return ended
    }

    mutating func pause(at now: TimerInstant) {
        guard !isOver, !isPaused else { return }
        bankedElapsed = elapsed(at: now)
        runningSince = nil
        isPaused = true
    }

    mutating func resume(at now: TimerInstant) {
        guard !isOver, isPaused else { return }
        runningSince = now
        isPaused = false
    }

    /// Ends the current phase early and starts the next one running, from its full length. Skipping
    /// the last phase ends the timer.
    mutating func skipPhase(at now: TimerInstant) {
        guard !isOver else { return }
        isPaused = false
        enterPhase(after: phase, carrying: 0, at: now)
    }

    mutating func cancel() {
        isOver = true
        isPaused = false
        runningSince = nil
        bankedElapsed = 0
    }

    private mutating func enterPhase(after ended: TimerPhase, carrying overshoot: TimeInterval, at now: TimerInstant) {
        let next: TimerPhase?
        switch program {
        case .countdown: next = nil
        case .pomodoro(let plan): next = plan.phase(after: ended)
        }
        guard let next else {
            cancel()
            return
        }
        phase = next
        bankedElapsed = overshoot
        runningSince = isPaused ? nil : now
    }
}
