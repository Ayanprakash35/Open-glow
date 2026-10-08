import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Stable identifier for persisting per-display settings. Unlike an array index — which
    /// shuffles whenever displays are connected/disconnected in a different order — this stays
    /// constant for the same physical display across launches and reconfigurations.
    var stableUUIDString: String? {
        guard let displayID, let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String
    }
}

/// Owns the set of overlay windows — one per connected, enabled display — and keeps it in sync
/// with the real display configuration, and hides them all while the glow is suspended.
///
/// `NSApplication.didChangeScreenParametersNotification` fires for display connect/disconnect,
/// resolution changes, scaling changes, and arrangement changes alike, so a single handler
/// re-diffs `NSScreen.screens` against the controllers we already have (matched by stable UUID,
/// not array position) rather than tearing everything down and rebuilding blind — that would
/// flash every window on unrelated changes and would drop per-display state keyed by a UUID that
/// never actually changed.
///
/// Sleep, the lock screen and the rest are `ScreenSessionMonitor`'s: `AppDelegate` sets `isSuspended`
/// from it, so a display that connects or reconfigures while the screen is locked or asleep stays
/// hidden too. Per-display sleep (an external monitor sleeping while others stay awake) isn't
/// tracked — that needs `CGDisplayRegisterReconfigurationCallback`, which is real added complexity.
@MainActor
final class DisplayManager {
    private var controllers: [String: OverlayWindowController] = [:]
    private var frameSource: (() -> AudioAnalysisState)?
    private let settings = Settings.shared
    private(set) var palette: GlowPalette = .fallback

    /// Called after the set of displays changes (connect, disconnect, reconfiguration).
    private var timerFraction: Double?
    private var timerRate: Double = 0

    var onDisplaysChanged: (() -> Void)?

    /// Whether any overlay is meant to be on screen, by the settings — capture has no reason to
    /// run otherwise. Doesn't consider `isSuspended`.
    var hasVisibleOverlay: Bool {
        settings.isEnabled && controllers.keys.contains { settings.isDisplayEnabled(uuid: $0) }
    }

    /// While true every overlay stays hidden — the screens are asleep or locked, the screen saver
    /// runs, or another user has the console. Clearing it shows them again as they were, with no
    /// opening sweep.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { applyVisibility() } }
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        rebuild()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Current displays, for the per-display toggles in the menu and popover.
    var displays: [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = screen.stableUUIDString else { return nil }
            return DisplayInfo(uuid: uuid, name: screen.localizedName, hasNotch: screen.auxiliaryTopLeftArea != nil)
        }
    }

    func applyVisibility() {
        for (uuid, controller) in controllers {
            shouldShow(uuid) ? controller.show() : controller.hide()
        }
    }

    private func shouldShow(_ uuid: String) -> Bool {
        !isSuspended && settings.isEnabled && settings.isDisplayEnabled(uuid: uuid)
    }

    /// Whether `displayID` is still connected. Online rather than in `NSScreen.screens`: a display
    /// that joins a mirror set leaves that list but stays connected, and capture tied to it works.
    nonisolated static func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(displayID) != 0
    }

    /// Re-applies the current notch-handling preference to every open overlay window immediately,
    /// rather than waiting for the next screen reconfiguration to pick it up.
    func refreshNotchMode() {
        for screen in NSScreen.screens {
            guard let uuid = screen.stableUUIDString, let controller = controllers[uuid] else { continue }
            controller.refreshNotchGeometry(screen: screen)
        }
    }

    /// Re-seeds every open window's look and motion from current settings — called on launch and
    /// whenever one of them changes. (New displays pick it up as they connect.)
    func applyBaseAppearanceToAll() {
        controllers.values.forEach(applyBaseAppearance)
    }

    /// The opening sweep on every visible display — at launch and when Open Glow is turned on.
    func playIntro() {
        for (uuid, controller) in controllers where shouldShow(uuid) {
            controller.playIntro()
        }
    }

    /// A short sweep in `palette`'s colors on every visible display (a coding session starting).
    func playAccent(_ palette: GlowPalette) {
        for (uuid, controller) in controllers where shouldShow(uuid) {
            controller.playAccent(palette)
        }
    }

    /// A running timer's remaining share (1 → 0) as a ring of light on every display, and on
    /// displays connected later; nil when no timer runs. `rate` is the share that goes per second
    /// while it runs (0 while paused), so the ring recedes smoothly between calls.
    func setTimerRing(remaining fraction: Double?, rate: Double = 0) {
        timerFraction = fraction
        timerRate = rate
        controllers.values.forEach { $0.setTimerRing(remaining: fraction, rate: rate) }
    }

    /// The finish pulses at the end of a timer or Pomodoro phase, on every visible display.
    func playTimerFinished() {
        for (uuid, controller) in controllers where shouldShow(uuid) {
            controller.playTimerFinished()
        }
    }

    /// Shows `newPalette` on every display, and on displays connected later.
    func setPalette(_ newPalette: GlowPalette, animated: Bool) {
        palette = newPalette
        controllers.values.forEach { $0.setPalette(newPalette, animated: animated) }
    }

    /// Music Sync on: every overlay (including displays connected later) animates from `source`.
    func startAudioFrames(source: @escaping () -> AudioAnalysisState) {
        frameSource = source
        controllers.values.forEach { $0.startAudioFrames(source: source) }
    }

    /// Music Sync off, or capture unavailable: every overlay returns to the idle flow.
    func stopAudioFrames() {
        frameSource = nil
        controllers.values.forEach { $0.stopAudioFrames() }
    }

    private func applyBaseAppearance(to controller: OverlayWindowController) {
        let animation: GlowAnimation = switch settings.animationMode {
        case .musicSync: .musicSync
        case .flow: .flow
        case .steady: .steady
        }
        controller.applyAppearance(GlowAppearance(
            brightness: settings.brightness,
            thickness: settings.thickness,
            softness: settings.softness,
            motion: GlowMotionSettings(
                animation: animation,
                flowSpeed: settings.flowSpeed,
                reactivity: Float(settings.reactivity) * GlowMotionConfig.maxReactivity,
                stereo: settings.stereoModeEnabled,
                // The system-wide Reduce Motion accessibility setting wins over ours.
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        ))
    }

    @objc private func screenParametersChanged() {
        rebuild()
    }

    private func rebuild() {
        let liveScreens = NSScreen.screens
        var liveUUIDs = Set<String>()

        for screen in liveScreens {
            guard let uuid = screen.stableUUIDString else { continue }
            liveUUIDs.insert(uuid)
            if let existing = controllers[uuid] {
                existing.updateScreen(screen)
            } else {
                // A display that connects mid-sweep joins without one — the sweep belongs to launch
                // and turning on — but with everything else the others have, music included.
                let controller = OverlayWindowController(screen: screen, displayUUID: uuid)
                applyBaseAppearance(to: controller)
                controller.setPalette(palette, animated: false)
                controller.setTimerRing(remaining: timerFraction, rate: timerRate)
                if let frameSource { controller.startAudioFrames(source: frameSource) }
                controllers[uuid] = controller
            }
        }

        for uuid in controllers.keys where !liveUUIDs.contains(uuid) {
            controllers.removeValue(forKey: uuid)?.tearDown()
        }

        applyVisibility()
        onDisplaysChanged?()
    }
}
