import AppKit

/// The glow's look and motion, as the settings and system describe them.
struct GlowAppearance: Equatable {
    var brightness: CGFloat
    var thickness: CGFloat
    var softness: CGFloat
    var motion: GlowMotionSettings
}

/// Owns one borderless, click-through overlay window sized to a single screen.
///
/// Window configuration notes (the incantations that are easy to get subtly wrong):
/// - `.borderless` + `isOpaque = false` + `backgroundColor = .clear` + `hasShadow = false` is what
///   makes the window itself invisible except for whatever the content view draws.
/// - `ignoresMouseEvents = true` lets clicks pass straight through to whatever app is beneath it.
/// - `collectionBehavior` with `.canJoinAllSpaces` + `.stationary` keeps the overlay present on
///   every Space without following window-switch animations; `.ignoresCycle` keeps it out of
///   Cmd+`/Mission Control window cycling; `.fullScreenAuxiliary` lets it coexist with another
///   app running full-screen on that display.
/// - `sharingType = .none` excludes the window from screen-capture/screenshot window pickers
///   (Cmd+Shift+5's window mode, Zoom/Slack screen-share pickers, etc.).
/// - We never call `makeKeyAndOrderFront`; `orderFrontRegardless()` shows the window without
///   stealing key/main status or activating the app.
@MainActor
final class OverlayWindowController: NSWindowController {
    let displayUUID: String
    private let glowView: GlowView

    init(screen: NSScreen, displayUUID: String) {
        self.displayUUID = displayUUID
        let view = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        glowView = view

        // With `screen:` given, AppKit treats contentRect as relative to that screen and adds
        // the screen's origin — passing the (already global) screen.frame would place windows
        // on every non-primary display at twice its origin, off-screen or half on.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = WindowConfig.level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.contentView = view

        super.init(window: window)
        // Belt and braces: pin the frame in global coordinates, as updateScreen does.
        window.setFrame(screen.frame, display: false)
        view.notchGeometry = Self.notchGeometry(for: screen)
    }

    required init?(coder: NSCoder) {
        fatalError("OverlayWindowController does not support NSCoder")
    }

    func show() {
        glowView.isHidden = false
        window?.orderFrontRegardless()
        glowView.didShow()
    }

    /// Hiding the view as well as the window is what pauses its display link: AppKit documents
    /// that a view's link doesn't fire while the view is hidden. Anything that moves meanwhile (a
    /// palette cross-fade) carries on from where it was when the overlay shows again.
    func hide() {
        window?.orderOut(nil)
        glowView.isHidden = true
    }

    /// For a display that's gone: hides the window and takes the view out of it, which ends the
    /// view's display link — the link retains the view and would otherwise keep it, and its
    /// frames, alive with the window.
    func tearDown() {
        glowView.stopAudioFrames()
        hide()
        window?.contentView = nil
        close()
    }

    /// Called when this same physical display's frame/resolution/scaling changes (still the same
    /// UUID) so the window and glow geometry stay in sync without tearing down and recreating.
    func updateScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
        glowView.notchGeometry = Self.notchGeometry(for: screen)
    }

    /// Called when the user flips the notch-handling preference, so open windows update live
    /// instead of waiting for the next screen reconfiguration.
    func refreshNotchGeometry(screen: NSScreen) {
        glowView.notchGeometry = Self.notchGeometry(for: screen)
    }

    func applyAppearance(_ appearance: GlowAppearance) {
        glowView.brightness = appearance.brightness
        glowView.thickness = appearance.thickness
        glowView.softness = appearance.softness
        glowView.motionSettings = appearance.motion
    }

    func setPalette(_ palette: GlowPalette, animated: Bool) {
        glowView.setPalette(palette, animated: animated)
    }

    func playIntro() {
        glowView.playIntro()
    }

    func playAccent(_ palette: GlowPalette) {
        glowView.playAccent(palette)
    }

    func setTimerRing(remaining fraction: Double?) {
        glowView.setTimerRing(remaining: fraction)
    }

    func playTimerFinished() {
        glowView.playTimerFinished()
    }

    /// Music Sync on: this overlay's view animates from `source` on its own display link.
    func startAudioFrames(source: @escaping () -> AudioAnalysisState) {
        glowView.startAudioFrames(source: source)
    }

    /// Music Sync off: back to the idle flow.
    func stopAudioFrames() {
        glowView.stopAudioFrames()
    }

    private static func notchGeometry(for screen: NSScreen) -> NotchGeometry? {
        guard Settings.shared.notchMode == .curveAround else { return nil }
        return NotchGeometry(screen: screen)
    }
}
