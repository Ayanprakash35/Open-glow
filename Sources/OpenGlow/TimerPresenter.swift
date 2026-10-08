import AppKit

/// Shows the running timer: the ring of light receding around every display, the finish pulses
/// at the end of each phase, the countdown in place of the menu-bar icon, and the popover's Timer
/// section.
@MainActor
final class TimerPresenter {
    let controller: TimerController
    /// The popover's Timer section, kept current on every tick and change.
    let panelModel: TimerPanelModel
    private let displayManager: DisplayManager
    private let statusItem: NSStatusItem
    private var showsCountdown = false

    /// Called once the countdown has left the menu bar, so the app can put its icon back.
    var onCountdownEnded: (() -> Void)?

    /// A problem the menu-bar icon would warn about, shown with the countdown while it stands in
    /// for the icon. Takes effect at once rather than at the next tick: a paused timer doesn't
    /// tick at all.
    var attention: TimerAttention? {
        didSet {
            guard attention != oldValue, showsCountdown, let snapshot = controller.snapshot else { return }
            TimerMenu.showCountdown(snapshot, attention: attention, in: statusItem)
        }
    }

    var isRunning: Bool { controller.snapshot != nil }

    init(displayManager: DisplayManager, statusItem: NSStatusItem, plan: PomodoroPlan = .standard) {
        let controller = TimerController()
        self.controller = controller
        panelModel = TimerPanelModel(plan: plan, actions: TimerMenu.Actions(controller: controller))
        self.displayManager = displayManager
        self.statusItem = statusItem
        controller.onUpdate = { [weak self] snapshot in self?.show(snapshot) }
        controller.onPhaseFinished = { [weak self] _ in self?.displayManager.playTimerFinished() }
    }

    /// The Timer submenu for the right-click menu: presets and Pomodoro, or the running timer's
    /// controls.
    func menuItem() -> NSMenuItem {
        TimerMenu.makeItem(for: controller.snapshot, plan: panelModel.plan, actions: TimerMenu.Actions(controller: controller))
    }

    private func show(_ snapshot: TimerSnapshot?) {
        panelModel.snapshot = snapshot
        // The pace lets the ring recede smoothly between these once-a-second updates.
        let rate = snapshot.map { $0.isPaused || $0.duration <= 0 ? 0 : 1 / $0.duration } ?? 0
        displayManager.setTimerRing(remaining: snapshot?.remainingFraction, rate: rate)
        if let snapshot {
            TimerMenu.showCountdown(snapshot, attention: attention, in: statusItem)
            // The countdown stays readable even while the glow itself is turned off.
            statusItem.button?.appearsDisabled = false
            showsCountdown = true
        } else if showsCountdown {
            TimerMenu.hideCountdown(in: statusItem)
            showsCountdown = false
            onCountdownEnded?()
        }
    }
}
