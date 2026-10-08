import AppKit
import os

/// Starting values for the glow's settings.
enum GlowDefaults {
    /// Peak opacity of the light at the screen edge, 0–1. Sane range: 0.4–1.
    static let brightness: CGFloat = 0.85
    /// Main falloff length in points: how far inward the light reaches before dimming to about a
    /// third. Sane range: 4–40.
    static let thickness: CGFloat = 10
    /// Share of the light in the long, faint tail (the bloom), 0–1. Sane range: 0.1–0.6.
    static let softness: CGFloat = 0.3
}

/// Frame pacing. How fast each kind of motion needs frames is `GlowMotion.frameRate`'s call.
enum GlowFrameConfig {
    /// Frame rates the display link is asked for, fastest first: whole fractions of 60 and 120 Hz,
    /// so each is met exactly. A request is rounded up to the next one.
    static let rates: [Double] = [60, 30, 20, 15, 12, 10, 6, 4, 2]
    /// Frames per second while Music Sync waits for audio with nothing else moving (Reduce
    /// Motion), so music starting is noticed. Sane range: 4–20.
    static let audioPollFrameRate: Double = 10
    /// A display tick this soon after the last frame, as a share of the asked-for interval, is
    /// skipped (the display runs faster than asked). Below 1 so normal jitter never drops a
    /// frame. Sane range: 0.6–0.9.
    static let earlyTickShare: Double = 0.75
    /// Longest a frame may be late, as a multiple of the asked-for interval, before the motion
    /// treats the gap as a stall rather than time to advance through. Sane range: 1.2–3.
    static let lateFrameShare: Double = 1.5
    /// Seconds between rebuilds of the strips while a setting that reshapes them keeps changing
    /// (a slider being dragged): each rebuild takes tens of milliseconds. Sane range: 0.03–0.2.
    static let reshapeInterval: Double = 0.08
}

/// Configuration for the overlay window's stacking level.
enum WindowConfig {
    /// `.screenSaver` sits above normal app windows and below system alerts (the sweet spot for
    /// an always-visible ambient overlay). Drop to `.statusBar` here if this ever fights with
    /// another always-on-top utility you run.
    static let level: NSWindow.Level = .screenSaver
}

/// Draws light coming in from the screen's edges and animates it: an idle flow of the palette's
/// colors around the screen, and in Music Sync, swells that travel along the edges with the music.
///
/// `GlowMotion` decides each moment's colors, brightness and widths around the perimeter;
/// `EdgeLightRasterizer` turns them into strip images along the edges (corners, notch, the spans
/// between them, and the sides), which this view shows as layer contents, scaled up smoothly. There are no masks, shadows or offscreen
/// passes. One display link drives everything while anything moves, at the frame rate the motion
/// needs (60 fps only for fast music swells and sweeps, ~20 for the idle flow, a few for a timer
/// ring alone). It stops when the glow holds still or the window can't be seen (covered, screen
/// locked or asleep), so a steady or hidden glow costs nothing per frame. Frames that would look
/// exactly like the last one aren't committed.
@MainActor
final class GlowView: NSView {
    private let motion = GlowMotion()
    private let rasterizer = EdgeLightRasterizer()
    private var stripLayers: [CALayer] = []
    private var link: CADisplayLink?
    /// The frame rate the link was asked for.
    private var linkRate: Double = 0
    private var lastTimestamp: CFTimeInterval?
    private var audioSource: (() -> AudioAnalysisState)?
    private var audioActive = false
    /// The palette as given (sRGB); `motion` holds it converted to the display's color space.
    private var palette: GlowPalette = .fallback
    private var colorSpace = EdgeLightRasterizer.Shape.sRGB
    private let logger = Logger(subsystem: "com.openglow.app", category: "GlowView")
    private var framesSinceReport = 0
    private var presentsSinceReport = 0
    private var lastReport: CFTimeInterval = 0
    /// When a settings change last rebuilt the strips, and whether another rebuild is waiting.
    private var lastSettingsReshape: CFTimeInterval = 0
    private var reshapeScheduled = false

    /// Peak opacity at the edge, 0...1.
    var brightness: CGFloat = GlowDefaults.brightness {
        didSet { if brightness != oldValue { redraw() } }
    }

    /// Main falloff length in points.
    var thickness: CGFloat = GlowDefaults.thickness {
        didSet { if thickness != oldValue { setNeedsReshape() } }
    }

    /// Share of the light in the faint tail, 0...1.
    var softness: CGFloat = GlowDefaults.softness {
        didSet { if softness != oldValue { setNeedsReshape() } }
    }

    var motionSettings = GlowMotionSettings() {
        didSet {
            guard motionSettings != oldValue else { return }
            // The widest swell depends on reactivity, and the strips are sized for it.
            if motionSettings.reactivity != oldValue.reactivity { setNeedsReshape() }
            redraw()
            updateLink()
        }
    }

    /// When set, the light wraps around the notch's outline. `nil` for screens without a notch, or
    /// when the notch is being ignored.
    var notchGeometry: NotchGeometry? {
        didSet { if notchGeometry != oldValue { reshape() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        reshape()
    }

    required init?(coder: NSCoder) {
        fatalError("GlowView does not support NSCoder")
    }

    // MARK: - Appearance

    func setPalette(_ palette: GlowPalette, animated: Bool) {
        self.palette = palette
        motion.setPalette(palette.converted(to: colorSpace), animated: animated && window != nil)
        redraw()
        updateLink()
    }

    /// Music Sync on: the light reacts to `source`.
    func startAudioFrames(source: @escaping () -> AudioAnalysisState) {
        audioSource = source
        updateLink()
    }

    /// Music Sync off, or capture unavailable: back to the idle flow.
    func stopAudioFrames() {
        audioSource = nil
        audioActive = false
        updateLink()
    }

    /// Plays the opening sweep: light rising from the bottom center around both sides.
    func playIntro() {
        motion.startIntro()
        lastTimestamp = nil
        redraw()
        updateLink()
    }

    /// Briefly takes on `palette` (sRGB): it sweeps in from the bottom center over the current
    /// glow, flows for `GlowMotionConfig.accentHoldSeconds`, then cross-fades back to the current
    /// palette (whatever it is by then). Calling again restarts it. With Reduce Motion it's a plain
    /// cross-fade in and back. Skipped while the window can't be seen: it's a moment's notice.
    func playAccent(_ palette: GlowPalette) {
        guard isOnScreen else { return }
        motion.playAccent(palette.converted(to: colorSpace))
        updateLink()
    }

    /// Shows a visual timer: only `fraction` of the perimeter stays lit, clockwise from the top
    /// center (1 = the whole edge, 0 = none), receding smoothly between updates — calling once a
    /// second is plenty. nil removes the ring (it refills, then the normal glow carries on); pass
    /// nil when the timer is cancelled or done.
    func setTimerRing(remaining fraction: Double?) {
        motion.setTimerRing(fraction)
        if !isOnScreen { motion.settleTimerRing() }
        updateLink()
    }

    /// The timer-finished flourish: three slow, soft pulses of the whole edge (about 2.5 s), then
    /// the normal glow without a ring. While the window can't be seen, just the ring goes.
    func playTimerFinished() {
        if isOnScreen {
            motion.playTimerFinished()
        } else {
            motion.setTimerRing(nil)
            motion.settleTimerRing()
        }
        updateLink()
    }

    /// Called whenever the overlay window is shown again.
    func didShow() {
        lastTimestamp = nil
        redraw()
        updateLink()
        // Frames start once the window server reports the window visible; check again in case
        // that report came before this call.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.updateLink()
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        reshape()
    }

    /// AppKit calls this for a new backing scale and for a new display color space (a color
    /// profile chosen in System Settings, HDR turned on).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        withoutAnimation { stripLayers.forEach { $0.contentsScale = scale } }
        reshape()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            center.removeObserver(self, name: NSWindow.didChangeScreenProfileNotification, object: window)
        }
        if let newWindow {
            center.addObserver(
                self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: newWindow
            )
            // Strips tagged with the old color space would be color-matched every frame.
            center.addObserver(
                self, selector: #selector(screenProfileChanged), name: NSWindow.didChangeScreenProfileNotification, object: newWindow
            )
        }
    }

    @objc private func screenProfileChanged(_ notification: Notification) {
        reshape()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reshape()
        // Without a window this stops the link, which retains this view.
        updateLink()
    }

    /// Whether any of the window shows: not ordered out, covered, on a locked screen or asleep.
    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        logger.debug("Overlay visible: \(self.isOnScreen, privacy: .public)")
        if isOnScreen {
            // Time passed unseen: carry on from now, with the timer ring where it should be and
            // no stale accent.
            lastTimestamp = nil
            motion.settleTimerRing()
            motion.cancelAccent()
            redraw()
        }
        updateLink()
    }

    /// Rebuilds the strips soon after a setting that shapes them changes: at once the first time,
    /// then at most every `GlowFrameConfig.reshapeInterval` while it keeps changing, and once more
    /// at the end so the last value always lands.
    private func setNeedsReshape() {
        guard !reshapeScheduled else { return }
        let wait = lastSettingsReshape + GlowFrameConfig.reshapeInterval - CACurrentMediaTime()
        guard wait > 0 else {
            lastSettingsReshape = CACurrentMediaTime()
            reshape()
            return
        }
        reshapeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            reshapeScheduled = false
            lastSettingsReshape = CACurrentMediaTime()
            reshape()
        }
    }

    /// Rebuilds the strips for the current size, notch, thickness, softness, reactivity and
    /// display color space.
    private func reshape() {
        let space = window?.screen?.colorSpace?.cgColorSpace
        let displaySpace = space.flatMap { $0.model == .rgb ? $0 : nil } ?? EdgeLightRasterizer.Shape.sRGB
        if displaySpace != colorSpace {
            colorSpace = displaySpace
            motion.setPalette(palette.converted(to: displaySpace), animated: false)
        }
        let shape = EdgeLightRasterizer.Shape(
            size: bounds.size,
            notch: notchGeometry,
            falloff: thickness,
            softness: Float(softness),
            maximumWidth: Self.maximumWidth(reactivity: motionSettings.reactivity),
            colorSpace: displaySpace
        )
        if rasterizer.configure(shape, cells: motion.count) {
            let geometry = EdgeGeometry(size: bounds.size, notch: notchGeometry)
            motion.perimeterPoints = Double(geometry.perimeter)
            motion.introOrigin = Double(geometry.point(at: CGPoint(x: bounds.midX, y: 0)).position)
            motion.ringOrigin = Double(geometry.point(at: CGPoint(x: bounds.midX, y: bounds.maxY)).position)
            motion.horizontalFraction = (0..<motion.count).map {
                Float(geometry.horizontalFraction(atPosition: CGFloat($0) / CGFloat(motion.count)))
            }
            rebuildLayers()
        }
        redraw()
    }

    /// Widest the glow gets, as a multiple of Thickness: the widest swell or idle patch, plus room
    /// for a sweep's head or a timer's finish pulse on top of it.
    static func maximumWidth(reactivity: Float) -> Float {
        let config = GlowMotionConfig.self
        let widest = max(config.musicWidthGain * reactivity, config.idleWidthDepth)
        let effects = max(config.introHeadBoost, config.accentHeadBoost, TimerRingConfig.headBoost, TimerRingConfig.pulseBoost)
        return 1 + widest + effects
    }

    private func rebuildLayers() {
        guard let root = layer else { return }
        withoutAnimation {
            stripLayers.forEach { $0.removeFromSuperlayer() }
            stripLayers = rasterizer.strips.map { strip in
                let strip = makeStripLayer(frame: strip.frame)
                root.addSublayer(strip)
                return strip
            }
        }
    }

    private func makeStripLayer(frame: CGRect) -> CALayer {
        let strip = CALayer()
        strip.frame = frame
        strip.contentsGravity = .resize
        // Linear filtering is what turns the coarse cells into a smooth gradient.
        strip.magnificationFilter = .linear
        strip.minificationFilter = .linear
        strip.contentsScale = window?.backingScaleFactor ?? 2
        strip.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        return strip
    }

    // MARK: - Frames

    /// Recomputes the light without advancing time — for setting changes while nothing moves.
    private func redraw() {
        motion.step(dt: 0, audio: audioActive ? audioSource?() : nil, settings: motionSettings)
        present()
    }

    private func present() {
        framesSinceReport += 1
        // Nothing to commit when the light is exactly as last drawn.
        guard let surfaces = rasterizer.render(motion, brightness: Float(brightness)) else { return }
        presentsSinceReport += 1
        withoutAnimation {
            for (layer, surface) in zip(stripLayers, surfaces) { layer.contents = surface }
        }
    }

    /// Starts, re-paces or stops the display link to match what the motion needs right now.
    private func updateLink() {
        var rate = isOnScreen ? motion.frameRate(motionSettings, audioActive: audioActive) : 0
        if isOnScreen, audioSource != nil, motionSettings.animation == .musicSync {
            rate = max(rate, GlowFrameConfig.audioPollFrameRate)
        }
        guard rate > 0 else {
            link?.invalidate()
            link = nil
            linkRate = 0
            return
        }
        let paced = GlowFrameConfig.rates.last { $0 >= rate } ?? GlowFrameConfig.rates.first ?? 60
        if link == nil {
            let newLink = displayLink(target: self, selector: #selector(frame(_:)))
            newLink.add(to: .main, forMode: .common)
            link = newLink
            linkRate = 0
            lastTimestamp = nil
        }
        if paced != linkRate, let link {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(paced / 2), maximum: Float(paced), preferred: Float(paced))
            linkRate = paced
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        // The display may tick faster than asked (another window wants its full rate): only do
        // the work this pace needs.
        if let previous = lastTimestamp, link.timestamp - previous < GlowFrameConfig.earlyTickShare / max(linkRate, 1) { return }
        let previous = lastTimestamp
        lastTimestamp = link.timestamp
        let dt = previous.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)

        var audio: AudioAnalysisState?
        if motionSettings.animation == .musicSync, let source = audioSource {
            let state = source()
            audioActive = state.hasAudio && !state.isSilent
            audio = state
        }
        // At a few frames a second each step is long by design, not a stall to skip.
        let maximumDt = max(GlowMotionConfig.maximumStepSeconds, GlowFrameConfig.lateFrameShare / max(linkRate, 1))
        motion.step(dt: dt, audio: audio, settings: motionSettings, maximumDt: maximumDt)
        present()
        if link.timestamp - lastReport >= 5 {
            if lastReport > 0 {
                logger.debug("\(self.framesSinceReport, privacy: .public) frames, \(self.presentsSinceReport, privacy: .public) drawn in \(link.timestamp - self.lastReport, format: .fixed(precision: 1), privacy: .public)s at \(self.linkRate, format: .fixed(precision: 0), privacy: .public) fps")
            }
            framesSinceReport = 0
            presentsSinceReport = 0
            lastReport = link.timestamp
        }
        updateLink()
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
