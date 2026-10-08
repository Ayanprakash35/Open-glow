import AppKit

/// Timer menu and menu-bar countdown tunables.
enum TimerMenuConfig {
    /// Countdown lengths offered in the menu, in minutes.
    static let presetMinutes = [5, 10, 15, 25, 45, 60]
    /// Longest custom countdown, in minutes. Sane range: 60–1440 (`GlowTimerConfig.maximumDuration`).
    static let maximumCustomMinutes = 24 * 60
    /// SF Symbols shown before the countdown in the menu bar.
    static let countdownSymbol = "timer"
    static let focusSymbol = "smallcircle.filled.circle"
    static let breakSymbol = "cup.and.saucer.fill"
    static let pausedSymbol = "pause.fill"
}

/// A problem the menu-bar icon would warn about if the countdown weren't standing in for it.
struct TimerAttention: Equatable {
    /// SF Symbol shown before the countdown in place of the timer glyph.
    var symbol: String
    /// What's wrong, added to the countdown's tooltip and VoiceOver text.
    var description: String
}

/// Builds the Timer submenu and the menu-bar countdown, and the titles the popover's Timer
/// section shares with them. Menu items call the closures in `Actions`, so the owner of the
/// status item only has to hook them up.
@MainActor
enum TimerMenu {
    /// What the Timer submenu's items and the popover's Timer section call.
    @MainActor
    struct Actions {
        var startCountdown: (TimeInterval) -> Void
        var startPomodoro: (PomodoroPlan) -> Void
        var pause: () -> Void
        var resume: () -> Void
        /// Skips the phase of this kind and round if it's still the current one, and does nothing
        /// otherwise; see `TimerController.skipPhase(expecting:round:)`.
        var skipPhase: (_ expecting: TimerKind, _ round: Int?) -> Void
        var cancel: () -> Void
        /// Asks for a custom length in minutes; nil when the user cancels.
        var askForCustomMinutes: () -> Int? = { TimerMenu.promptForCustomMinutes() }
    }

    // MARK: Menu

    /// The "Timer" item: presets, Custom… and Pomodoro when idle; the time left and controls
    /// while a timer runs.
    static func makeItem(for snapshot: TimerSnapshot?, plan: PomodoroPlan = .standard, actions: Actions) -> NSMenuItem {
        let item = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if let snapshot {
            addRunningItems(for: snapshot, to: submenu, actions: actions)
        } else {
            addIdleItems(to: submenu, plan: plan, actions: actions)
        }
        item.submenu = submenu
        return item
    }

    private static func addIdleItems(to menu: NSMenu, plan: PomodoroPlan, actions: Actions) {
        for minutes in TimerMenuConfig.presetMinutes {
            menu.addItem(actionItem(presetTitle(minutes: minutes)) { actions.startCountdown(minutes: minutes) })
        }
        menu.addItem(actionItem("Custom…", action: actions.startCustomCountdown))
        menu.addItem(.separator())
        menu.addItem(actionItem(pomodoroTitle(for: plan)) { actions.startPomodoro(plan) })
    }

    private static func addRunningItems(for snapshot: TimerSnapshot, to menu: NSMenu, actions: Actions) {
        let header = NSMenuItem(title: headerTitle(for: snapshot), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(snapshot.isPaused ? actionItem("Resume", action: actions.resume) : actionItem("Pause", action: actions.pause))
        if let skipTitle = skipTitle(for: snapshot) {
            // The menu stays open while the timer ticks, so the item names the phase it was built
            // for: if that phase runs out before the click, the one after it isn't skipped instead.
            menu.addItem(actionItem(skipTitle) { actions.skipPhase(snapshot.kind, snapshot.round) })
        }
        menu.addItem(actionItem("Cancel Timer", action: actions.cancel))
    }

    /// "Start Pomodoro (25/5)": focus and short-break minutes.
    static func pomodoroTitle(for plan: PomodoroPlan) -> String {
        let focus = Int((plan.focus / 60).rounded())
        let pause = Int((plan.shortBreak / 60).rounded())
        return "Start Pomodoro (\(focus)/\(pause))"
    }

    /// The skip command's title, or nil for a countdown, which has nothing to skip to. On a
    /// Pomodoro's last phase skipping ends the session, so it says so rather than promising a
    /// next phase.
    static func skipTitle(for snapshot: TimerSnapshot) -> String? {
        guard snapshot.kind != .countdown else { return nil }
        if snapshot.isLastPhase { return "Finish Pomodoro" }
        return snapshot.kind == .focus ? "Skip to Break" : "Skip Break"
    }

    /// "5 Minutes", "1 Hour", "90 Minutes".
    static func presetTitle(minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 Hour" : "\(hours) Hours"
        }
        return minutes == 1 ? "1 Minute" : "\(minutes) Minutes"
    }

    /// The disabled first line of the running menu, e.g. "Focus 2 of 4 — 24:13 left".
    static func headerTitle(for snapshot: TimerSnapshot) -> String {
        let time = clockString(seconds: snapshot.displaySeconds)
        let state = snapshot.isPaused ? "paused at \(time)" : "\(time) left"
        return "\(phaseName(for: snapshot)) — \(state)"
    }

    /// "Timer", "Focus 2 of 4", "Short Break" or "Long Break".
    static func phaseName(for snapshot: TimerSnapshot) -> String {
        switch snapshot.kind {
        case .countdown:
            return "Timer"
        case .focus:
            if let round = snapshot.round, let rounds = snapshot.rounds { return "Focus \(round) of \(rounds)" }
            return "Focus"
        case .shortBreak:
            return "Short Break"
        case .longBreak:
            return "Long Break"
        }
    }

    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction(_:)), keyEquivalent: "")
        item.target = handler
        // `target` is weak; the item keeps its handler alive through this.
        item.representedObject = handler
        return item
    }

    // MARK: Menu bar

    /// "4:59", "24:00", "1:02:03".
    static func clockString(seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The countdown in the menu-bar font with monospaced digits, so it doesn't jitter as it
    /// counts. No color: the status button draws it in the menu bar's own text color.
    static func statusTitle(for snapshot: TimerSnapshot) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSAttributedString(
            string: clockString(seconds: snapshot.displaySeconds),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
        )
    }

    /// The SF Symbol for the phase: a timer, a focus dot or a cup, or pause while paused.
    static func statusSymbol(for snapshot: TimerSnapshot) -> String {
        if snapshot.isPaused { return TimerMenuConfig.pausedSymbol }
        switch snapshot.kind {
        case .countdown: return TimerMenuConfig.countdownSymbol
        case .focus: return TimerMenuConfig.focusSymbol
        case .shortBreak, .longBreak: return TimerMenuConfig.breakSymbol
        }
    }

    /// The glyph before the countdown: the phase's symbol, or the warning's while there is one.
    static func statusImage(for snapshot: TimerSnapshot, attention: TimerAttention? = nil) -> NSImage? {
        let name = attention?.symbol ?? statusSymbol(for: snapshot)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: statusDescription(for: snapshot, attention: attention))
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small))
    }

    /// Tooltip and VoiceOver text, e.g. "Open Glow — Focus 2 of 4 — 24:13 left", with the
    /// warning on a line of its own when there is one.
    static func statusDescription(for snapshot: TimerSnapshot, attention: TimerAttention? = nil) -> String {
        let timer = "Open Glow — \(headerTitle(for: snapshot))"
        guard let attention else { return timer }
        return timer + "\n" + attention.description
    }

    /// Shows the countdown in place of the icon, led by `attention`'s symbol when there's
    /// something to warn about. The status item needs `variableLength` to fit it;
    /// `showCountdown(_:attention:in:)` sets that too.
    static func showCountdown(_ snapshot: TimerSnapshot, attention: TimerAttention? = nil, on button: NSButton) {
        button.image = statusImage(for: snapshot, attention: attention)
        button.imagePosition = .imageLeading
        button.attributedTitle = statusTitle(for: snapshot)
        button.toolTip = statusDescription(for: snapshot, attention: attention)
    }

    /// Removes the countdown; the owner then puts its own icon back.
    static func hideCountdown(on button: NSButton) {
        button.title = ""
        button.imagePosition = .imageOnly
    }

    static func showCountdown(_ snapshot: TimerSnapshot, attention: TimerAttention? = nil, in item: NSStatusItem) {
        item.length = NSStatusItem.variableLength
        if let button = item.button { showCountdown(snapshot, attention: attention, on: button) }
    }

    static func hideCountdown(in item: NSStatusItem) {
        item.length = NSStatusItem.squareLength
        if let button = item.button { hideCountdown(on: button) }
    }

    // MARK: Custom length

    /// Whole minutes ("20") or hours and minutes ("1:30"), 1...`maximumCustomMinutes`; nil otherwise.
    static func parseMinutes(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        let minutes: Int
        switch parts.count {
        case 1:
            guard let whole = wholeNumber(parts[0]) else { return nil }
            minutes = whole
        case 2:
            guard let hours = wholeNumber(parts[0]), let mins = wholeNumber(parts[1]), parts[1].count == 2, mins < 60 else { return nil }
            minutes = hours * 60 + mins
        default:
            return nil
        }
        return (1...TimerMenuConfig.maximumCustomMinutes).contains(minutes) ? minutes : nil
    }

    private static func wholeNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
        return Int(text)
    }

    /// A small alert asking for the length; asks again, with a hint, until the entry is valid or
    /// the user cancels.
    static func promptForCustomMinutes() -> Int? {
        var entry = ""
        var hint = "Enter minutes, or hours and minutes like 1:30."
        while true {
            let alert = NSAlert()
            alert.messageText = "Custom Timer"
            alert.informativeText = hint
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.stringValue = entry
            field.placeholderString = "Minutes"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            // A menu-bar app isn't frontmost; without this the alert opens behind other windows.
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            entry = field.stringValue
            if let minutes = parseMinutes(entry) { return minutes }
            hint = "“\(entry)” isn't a length from 1 minute to \(TimerMenuConfig.maximumCustomMinutes / 60) hours. "
                + "Enter minutes, or hours and minutes like 1:30."
        }
    }
}

extension TimerMenu.Actions {
    /// Actions that drive `controller`.
    init(controller: TimerController) {
        self.init(
            startCountdown: { [weak controller] in controller?.startCountdown($0) },
            startPomodoro: { [weak controller] in controller?.startPomodoro($0) },
            pause: { [weak controller] in controller?.pause() },
            resume: { [weak controller] in controller?.resume() },
            skipPhase: { [weak controller] in controller?.skipPhase(expecting: $0, round: $1) },
            cancel: { [weak controller] in controller?.cancel() }
        )
    }

    /// Starts a countdown of `minutes` whole minutes.
    func startCountdown(minutes: Int) {
        startCountdown(TimeInterval(minutes) * 60)
    }

    /// Asks for a length and starts it; does nothing if the user cancels.
    func startCustomCountdown() {
        if let minutes = askForCustomMinutes() { startCountdown(minutes: minutes) }
    }
}

/// Runs a closure as a menu item's action.
@MainActor
private final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func runAction(_ sender: Any?) {
        run()
    }
}
