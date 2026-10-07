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

/// Frame pacing.
enum GlowFrameConfig {
    /// While music is playing: smooth enough for quick swells.
    static let musicFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    /// While only the slow idle flow moves.
    static let flowFrameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
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
/// `EdgeLightRasterizer` turns them into four strip images (top, bottom, left, right), which this
/// view shows as layer contents, scaled up smoothly. There are no masks, shadows or offscreen
/// passes. One display link drives everything while anything moves, and stops when the glow
/// holds still, so a steady glow costs nothing per frame.
@MainActor
final class GlowView: NSView {
    private let motion = GlowMotion()
    private let rasterizer = EdgeLightRasterizer()
    private var stripLayers: [CALayer] = []
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var audioSource: (() -> AudioAnalysisState)?
    private var audioActive = false
    /// The palette as given (sRGB); `motion` holds it converted to the display's color space.
    private var palette: GlowPalette = .fallback
    private var colorSpace = EdgeLightRasterizer.Shape.sRGB
    private let logger = Logger(subsystem: "com.openglow.app", category: "GlowView")
    private var framesSinceReport = 0
    private var lastReport: CFTimeInterval = 0

    /// Peak opacity at the edge, 0...1.
    var brightness: CGFloat = GlowDefaults.brightness {
        didSet { if brightness != oldValue { redraw() } }
    }

    /// Main falloff length in points.
    var thickness: CGFloat = GlowDefaults.thickness {
        didSet { if thickness != oldValue { reshape() } }
    }

    /// Share of the light in the faint tail, 0...1.
    var softness: CGFloat = GlowDefaults.softness {
        didSet { if softness != oldValue { reshape() } }
    }

    var motionSettings = GlowMotionSettings() {
        didSet {
            guard motionSettings != oldValue else { return }
            // The widest swell depends on reactivity, and the strips are sized for it.
            if motionSettings.reactivity != oldValue.reactivity { reshape() } else { redraw() }
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

    /// Called whenever the overlay window is shown again.
    func didShow() {
        lastTimestamp = nil
        redraw()
        updateLink()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        reshape()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        withoutAnimation { stripLayers.forEach { $0.contentsScale = scale } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reshape()
        if window == nil {
            // The display link retains this view; don't let it outlive the window.
            link?.invalidate()
            link = nil
        } else {
            updateLink()
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
            maximumWidth: 1 + max(GlowMotionConfig.musicWidthGain * motionSettings.reactivity, GlowMotionConfig.idleWidthDepth),
            colorSpace: displaySpace
        )
        if rasterizer.configure(shape, cells: motion.count) {
            let geometry = EdgeGeometry(size: bounds.size, notch: notchGeometry)
            motion.perimeterPoints = Double(geometry.perimeter)
            motion.introOrigin = Double(geometry.point(at: CGPoint(x: bounds.midX, y: 0)).position)
            motion.horizontalFraction = (0..<motion.count).map {
                Float(geometry.horizontalFraction(atPosition: CGFloat($0) / CGFloat(motion.count)))
            }
            rebuildLayers()
        }
        redraw()
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
        let images = rasterizer.render(motion, brightness: Float(brightness))
        withoutAnimation {
            for (layer, image) in zip(stripLayers, images) { layer.contents = image }
        }
    }

    private func updateLink() {
        let wantsAudio = audioSource != nil && motionSettings.animation == .musicSync
        let wantsFrames = window != nil
            && (wantsAudio || motion.needsFrames(motionSettings, audioActive: audioActive))
        if wantsFrames, link == nil {
            let newLink = displayLink(target: self, selector: #selector(frame(_:)))
            newLink.preferredFrameRateRange = GlowFrameConfig.flowFrameRate
            newLink.add(to: .main, forMode: .common)
            link = newLink
            lastTimestamp = nil
        } else if !wantsFrames, let existing = link {
            existing.invalidate()
            link = nil
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let previous = lastTimestamp
        lastTimestamp = link.timestamp
        let dt = previous.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)

        var audio: AudioAnalysisState?
        if motionSettings.animation == .musicSync, let source = audioSource {
            let state = source()
            let active = state.hasAudio && !state.isSilent
            if active != audioActive {
                audioActive = active
                link.preferredFrameRateRange = active ? GlowFrameConfig.musicFrameRate : GlowFrameConfig.flowFrameRate
            }
            audio = state
        }
        motion.step(dt: dt, audio: audio, settings: motionSettings)
        present()
        framesSinceReport += 1
        if link.timestamp - lastReport >= 5 {
            if lastReport > 0 {
                logger.debug("Drew \(self.framesSinceReport, privacy: .public) frames in \(link.timestamp - self.lastReport, format: .fixed(precision: 1), privacy: .public)s")
            }
            framesSinceReport = 0
            lastReport = link.timestamp
        }
        if !motion.needsFrames(motionSettings, audioActive: audioActive), audioSource == nil || motionSettings.animation != .musicSync {
            link.invalidate()
            self.link = nil
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
