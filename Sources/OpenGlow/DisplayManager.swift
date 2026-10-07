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
/// with the real display configuration and system sleep state.
///
/// `NSApplication.didChangeScreenParametersNotification` fires for display connect/disconnect,
/// resolution changes, scaling changes, and arrangement changes alike, so a single handler
/// re-diffs `NSScreen.screens` against the controllers we already have (matched by stable UUID,
/// not array position) rather than tearing everything down and rebuilding blind — that would
/// flash every window on unrelated changes and would drop per-display state keyed by a UUID that
/// never actually changed.
///
/// Per-display sleep detection (an external monitor sleeping independently while others stay
/// awake) still isn't implemented — that needs a lower-level `CGDisplayRegisterReconfigurationCallback`,
/// which is real added complexity. What's implemented is whole-system sleep/wake (lid close,
/// display sleep from System Settings or `pmset displaysleepnow`); `AppDelegate` observes the same
/// notifications separately to pause audio capture and the render loop at the same time.
@MainActor
final class DisplayManager {
    private var controllers: [String: OverlayWindowController] = [:]
    private var frameSource: (() -> AudioAnalysisState)?
    private let settings = Settings.shared
    private(set) var palette: GlowPalette = .fallback

    /// Called after the set of displays changes (connect, disconnect, reconfiguration).
    var onDisplaysChanged: (() -> Void)?

    /// Whether any overlay is meant to be on screen — capture has no reason to run otherwise.
    var hasVisibleOverlay: Bool {
        settings.isEnabled && controllers.keys.contains { settings.isDisplayEnabled(uuid: $0) }
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        rebuild()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
            let shouldShow = settings.isEnabled && settings.isDisplayEnabled(uuid: uuid)
            shouldShow ? controller.show() : controller.hide()
        }
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
        for (uuid, controller) in controllers where settings.isEnabled && settings.isDisplayEnabled(uuid: uuid) {
            controller.playIntro()
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

    @objc private func screensDidSleep() {
        controllers.values.forEach { $0.hide() }
    }

    @objc private func screensDidWake() {
        applyVisibility()
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
                let controller = OverlayWindowController(screen: screen, displayUUID: uuid)
                applyBaseAppearance(to: controller)
                controller.setPalette(palette, animated: false)
                if let frameSource { controller.startAudioFrames(source: frameSource) }
                controllers[uuid] = controller
            }
        }

        for uuid in controllers.keys where !liveUUIDs.contains(uuid) {
            // Stop the link first: it retains the view and would otherwise keep firing for a
            // display that no longer exists.
            controllers[uuid]?.stopAudioFrames()
            controllers[uuid]?.hide()
            controllers.removeValue(forKey: uuid)
        }

        applyVisibility()
        onDisplaysChanged?()
    }
}
