import AppKit

/// Ticking and sound tunables for the running timer.
enum TimerControllerConfig {
    /// Seconds past each displayed-second boundary a tick lands, so it never reads the second
    /// it's replacing. Sane range: 0.001–0.05.
    static let tickSlack: TimeInterval = 0.005
    /// Seconds the system may defer a tick to batch wake-ups. Sane range: 0–0.1.
    static let tickTolerance: TimeInterval = 0.02
    /// System sound played when a phase ends: a name from /System/Library/Sounds.
    static let phaseEndSoundName = "Glass"
    /// Volume of that sound, 0–1. Sane range: 0.2–1.
    static let phaseEndSoundVolume: Float = 0.6
}

/// Runs the current timer: ticks when its display changes and exactly at phase ends, and
/// reports each change. Holds one timer at a time; starting another replaces it.
@MainActor
final class TimerController: NSObject {
    /// Called after every change and tick with the current state; nil once no timer runs.
    var onUpdate: ((TimerSnapshot?) -> Void)?
    /// Called when a phase runs out, with that phase at zero, before `onUpdate` reports what
    /// comes next. Phases that all ended during one sleep are reported once, as the last of them.
    var onPhaseFinished: ((TimerSnapshot) -> Void)?

    private(set) var timer: GlowTimer?
    private let clock: () -> TimerInstant
    private let playSoundOverride: (() -> Void)?
    private lazy var phaseEndSound: NSSound? = {
        let sound = NSSound(named: TimerControllerConfig.phaseEndSoundName)
        sound?.volume = TimerControllerConfig.phaseEndSoundVolume
        return sound
    }()
    private var tickTimer: Timer?
    private var napPrevention: NapPrevention?

    /// - Parameters:
    ///   - clock: The current instant; tests pass their own.
    ///   - playSound: Replaces the phase-end system sound; tests pass their own.
    init(clock: @escaping () -> TimerInstant = TimerInstant.now, playSound: (() -> Void)? = nil) {
        self.clock = clock
        self.playSoundOverride = playSound
        super.init()
        // Run-loop timers stall while the Mac sleeps, so catch up as soon as it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// The state right now; nil when no timer runs.
    var snapshot: TimerSnapshot? { timer?.snapshot(at: clock()) }

    var isPomodoro: Bool { timer?.isPomodoro ?? false }

    // MARK: Commands

    func startCountdown(_ duration: TimeInterval) {
        start(.countdown(duration))
    }

    func startPomodoro(_ plan: PomodoroPlan = .standard) {
        start(.pomodoro(plan))
    }

    func pause() { change { $0.pause(at: $1) } }
    func resume() { change { $0.resume(at: $1) } }

    func togglePause() {
        if timer?.isPaused == true { resume() } else { pause() }
    }

    /// Skips the phase the user was looking at, given as the `kind` and `round` it showed, and
    /// does nothing if that phase is no longer current. A menu or popover keeps showing what it
    /// was built from while the timer ticks underneath, so "Skip to Break" can be clicked a moment
    /// after the focus round ran out on its own. By then the break has started, and skipping
    /// whatever is current would skip the break too.
    func skipPhase(expecting kind: TimerKind, round: Int?) {
        change { timer, now in
            // `change` has already settled any ended phase, so `phase` is what's current now.
            guard timer.phase.kind == kind, timer.phase.round == round else { return }
            timer.skipPhase(at: now)
        }
    }

    func cancel() {
        guard timer != nil else { return }
        timer = nil
        publish(at: clock())
    }

    // MARK: Ticking

    /// Brings the timer up to now: reports ended phases, then the current state. Internal so
    /// tests can drive it without a run loop.
    func tick() {
        guard timer != nil else { return }
        let now = clock()
        finishEndedPhases(at: now)
        publish(at: now)
    }

    @objc private func systemDidWake() {
        tick()
    }

    private func start(_ program: GlowTimer.Program) {
        let now = clock()
        timer = GlowTimer(program, startingAt: now)
        publish(at: now)
    }

    /// Applies a command after settling any phase that ended just before it, so an end is
    /// never swallowed by a pause or skip that raced the tick.
    private func change(_ apply: (inout GlowTimer, TimerInstant) -> Void) {
        guard timer != nil else { return }
        let now = clock()
        finishEndedPhases(at: now)
        if var current = timer {
            apply(&current, now)
            timer = current.isOver ? nil : current
        }
        publish(at: now)
    }

    private func finishEndedPhases(at now: TimerInstant) {
        guard var current = timer else { return }
        let ended = current.advance(to: now)
        timer = current.isOver ? nil : current
        guard let last = ended.last else { return }
        playPhaseEndSound()
        onPhaseFinished?(current.snapshot(ofEnded: last))
    }

    private func publish(at now: TimerInstant) {
        scheduleTick(at: now)
        let running = timer.map { !$0.isPaused } ?? false
        if running, napPrevention == nil {
            napPrevention = NapPrevention()
        } else if !running {
            napPrevention = nil
        }
        onUpdate?(timer?.snapshot(at: now))
    }

    private func scheduleTick(at now: TimerInstant) {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let delay = timer?.secondsUntilNextTick(at: now) else { return }
        let next = Timer(timeInterval: delay + TimerControllerConfig.tickSlack, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = TimerControllerConfig.tickTolerance
        // Common modes keep the countdown moving while a menu is open.
        RunLoop.main.add(next, forMode: .common)
        tickTimer = next
    }

    private func playPhaseEndSound() {
        if let playSoundOverride {
            playSoundOverride()
        } else if let phaseEndSound {
            phaseEndSound.stop()
            phaseEndSound.play()
        }
    }
}

/// Keeps App Nap from deferring ticks while a timer counts down, for as long as it lives. Without
/// it, with the glow off and no window on screen, the menu-bar countdown could stall for seconds.
private final class NapPrevention {
    private let token: NSObjectProtocol

    init() {
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Open Glow timer is counting down"
        )
    }

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}
