import AppKit

/// Shows the running timer: the ring of light receding around every display, the finish pulses
/// at the end of each phase, and the countdown in place of the menu-bar icon.
@MainActor
final class TimerPresenter {
    let controller = TimerController()
    private let displayManager: DisplayManager
    private let statusItem: NSStatusItem
    private var showsCountdown = false

    /// Called once the countdown has left the menu bar, so the app can put its icon back.
    var onCountdownEnded: (() -> Void)?

    var isRunning: Bool { controller.snapshot != nil }

    init(displayManager: DisplayManager, statusItem: NSStatusItem) {
        self.displayManager = displayManager
        self.statusItem = statusItem
        controller.onUpdate = { [weak self] snapshot in self?.show(snapshot) }
        controller.onPhaseFinished = { [weak self] _ in self?.displayManager.playTimerFinished() }
    }

    /// The Timer submenu for the right-click menu: presets and Pomodoro, or the running timer's
    /// controls.
    func menuItem() -> NSMenuItem {
        TimerMenu.makeItem(for: controller.snapshot, actions: TimerMenu.Actions(controller: controller))
    }

    private func show(_ snapshot: TimerSnapshot?) {
        displayManager.setTimerRing(remaining: snapshot?.remainingFraction)
        if let snapshot {
            TimerMenu.showCountdown(snapshot, in: statusItem)
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
