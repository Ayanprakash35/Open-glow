import Foundation

/// How the edge light moves.
enum GlowAnimation: Equatable {
    /// Reacts to system audio; flows gently while nothing plays.
    case musicSync
    /// Colors and light drift slowly around the screen; audio is ignored.
    case flow
    /// Holds still.
    case steady
}

/// The settings that shape motion, as the renderer needs them.
struct GlowMotionSettings: Equatable {
    var animation: GlowAnimation = .musicSync
    /// Multiplier on how fast the colors travel, 0.25...3 (1 = `flowLapSeconds` per lap).
    var flowSpeed: Double = 1
    /// Multiplier on every music-driven change, 0...`maxReactivity` (1 = the tuned default).
    var reactivity: Float = 1
    var stereo = false
    /// The system Reduce Motion setting: nothing travels or drifts; music still brightens the glow.
    var reduceMotion = false
}

/// The motion "feel" knobs.
enum GlowMotionConfig {
    /// Points around the screen the light is computed at, smoothly blended between. Sane range: 240–720.
    static let perimeterCells = 480

    // MARK: Flow (idle, and the Flow mode)

    /// Seconds for the colors to travel once around the screen at Flow speed 1. Sane range: 10–120.
    static let flowLapSeconds: Double = 26
    /// Seconds for the slow wobble that keeps the color blobs changing shape. Sane range: 10–60.
    static let wobbleSeconds: Double = 23
    /// Softness of the hand-over between the two colors, as a share of the color field. Sane range: 0.05–0.4.
    static let colorSoftness: Float = 0.24
    /// How uneven the brightness is along the edge while idle — soft brighter and dimmer patches
    /// drifting with the colors. 0 = even. Sane range: 0–0.6.
    static let idlePatchDepth: Float = 0.38
    /// Slow breathing of the whole glow while idle: period in seconds and depth (0–0.3).
    static let idleBreathSeconds: Double = 6.5
    static let idleBreathDepth: Float = 0.14
    /// How much the idle patches bulge the glow inward (0 = none). Sane range: 0–0.4.
    static let idleWidthDepth: Float = 0.18

    // MARK: Music

    /// Seconds for a swell to rise and to fall back. A slow fall is what makes music read as a
    /// flowing swell instead of a thump. Sane ranges: attack 0.04–0.25, release 0.25–1.2.
    static let envelopeAttackSeconds: Double = 0.16
    static let envelopeReleaseSeconds: Double = 0.65
    /// Seconds a beat's strength lingers before the swell lets go of it. The detector's pulse
    /// is a quick spike; holding it a little lets the slower rise above actually reach it.
    /// Sane range: 0.1–0.6.
    static let beatHoldSeconds: Double = 0.3
    /// Gain from a beat (graded by size: big hits ≈ 1, small ≈ 0.1–0.3) to the swell, which is
    /// capped at 1. Above 1 because the held beat still fades while the swell rises — at 1.8 a
    /// big hit swells to about 90%, a small one to about 20%. Sane range: 0.8–2.5.
    static let beatWeight: Float = 1.8
    /// How much sustained bass drives a swell, above `bassThreshold` (bass is 0–1 relative to the
    /// track's own range). 0–1.
    static let bassWeight: Float = 0.45
    static let bassThreshold: Float = 0.6
    /// Points per second a swell travels along the edge from where it starts. Sane range: 600–4000.
    static let swellSpeed: Double = 2200
    /// How much of a swell has faded by the time it's a quarter of the way around. Sane range: 0–0.8.
    static let swellTravelFade: Float = 0.45
    /// Where swells start, as positions around the screen (0 = top-left, clockwise): the middle
    /// of the bottom and top edges, drifting with the colors.
    static let swellOrigins: [Double] = [0.125, 0.625]
    /// Brightness between swells at default reactivity, as a share of full. Sane range: 0–0.6.
    static let musicFloor: Float = 0.22
    /// How much a full swell widens the glow at default reactivity (1 = double). Sane range: 0–2.
    static let musicWidthGain: Float = 1.1
    /// How much faster the colors travel at full swell. Sane range: 0–4.
    static let musicFlowBoost: Double = 2.0
    /// Seconds to blend between idle flow and music swells as music starts or stops.
    static let musicBlendSeconds: Double = 0.9
    /// Stereo: the quieter side's brightness never drops below this share of the louder one's.
    static let stereoFloor: Float = 0.35
    /// Seconds of envelope history kept: enough for a swell to reach the farthest point it
    /// travels to (half the distance between origins) on a large display, plus margin.
    static let historySeconds: Double = 1.5

    /// Seconds to cross-fade to a new palette (a track change, a preset).
    static let paletteFadeSeconds: Double = 0.8

    // MARK: Opening

    /// Seconds for the opening sweep: light rises from the bottom center, runs up both sides and
    /// meets at the top, then its bright head fades into the idle flow. Sane range: 1–4.
    static let introSeconds: Double = 2.2
    /// Share of `introSeconds` the two fronts take to meet at the top; the rest is the settle.
    static let introSweepShare: Double = 0.7
    /// Softness of the sweep's leading edge, as a share of the way around. Sane range: 0.01–0.1.
    static let introEdgeSoftness: Double = 0.035
    /// Extra brightness and width of the sweep's bright head (0 = no head). Sane range: 0–1.
    static let introHeadBoost: Float = 0.7
    /// The Reactivity setting (0...1) scales music by up to this factor; 0.5 gives the values above.
    static let maxReactivity: Float = 2

    // MARK: Accent

    /// Seconds for an accent's sweep: like the opening, from the bottom center up both sides,
    /// over the current glow. Sane range: 0.6–2.5.
    static let accentSweepSeconds: Double = 1.3
    /// Seconds the accent colors flow once the sweep has met at the top. Sane range: 2–15.
    static let accentHoldSeconds: Double = 5
    /// Seconds to cross-fade back to the current palette (and, with Reduce Motion, to fade the
    /// accent in). Sane range: 0.5–3.
    static let accentFadeSeconds: Double = 1.2
    /// Seconds for the sweep's bright head to fade once the fronts meet. Sane range: 0.2–1.5.
    static let accentSettleSeconds: Double = 0.6
    /// Extra brightness and width of the sweep's head. Sane range: 0–1.
    static let accentHeadBoost: Float = 0.7

    // MARK: Frame pacing

    /// Frames per second the idle flow gets at Flow speed 1, scaled with the speed. The colors
    /// drift slowly and their hand-overs are soft, so this is well below the display's rate.
    /// Sane range: 15–30.
    static let flowFrameRate: Double = 20
    /// Slowest and fastest frame rates for the flow, whatever the speed. Sane ranges: 8–15, 20–60.
    static let flowFrameRateRange: ClosedRange<Double> = 10...30
    /// Music gets full frame rate while the swell changes faster than this (share of full per
    /// second); otherwise half. Sane range: 0.2–1.5.
    static let fastMusicRate: Float = 0.5
    /// Seconds full frame rate is kept after the swell last changed fast: long enough for that
    /// change to travel to the farthest point. Sane range: 0.5–1.5.
    static let fastMusicHoldSeconds: Double = 0.8
    /// Music's two frame rates. Sane ranges: 45–120 and 20–40.
    static let fastMusicFrameRate: Double = 60
    static let slowMusicFrameRate: Double = 30
    /// Frame rate for cross-fades: palettes, music starting or stopping. Sane range: 20–60.
    static let fadeFrameRate: Double = 30
}

/// The edge light's state from moment to moment: for every cell around the screen, its color,
/// brightness and how far inward its glow reaches. Updated once per frame from time, settings and
/// (in Music Sync) the latest audio analysis; `EdgeLightRasterizer` turns it into pixels.
///
/// Colors come from a smooth field — a few cosines around the perimeter — thresholded into the
/// palette's two colors with soft hand-overs, so each color forms broad blobs. The field slides
/// counter-clockwise (the flow) while slow phase drift keeps the blobs changing shape. In Music
/// Sync a one-pole envelope with a quick rise and slow fall turns beats and bass into swells;
/// each swell starts at two points and travels outward along the edge, read from a short history
/// of the envelope, so the light flows around the screen with the music rather than flashing.
@MainActor
final class GlowMotion {
    let count = GlowMotionConfig.perimeterCells

    private(set) var red: [Float]
    private(set) var green: [Float]
    private(set) var blue: [Float]
    /// 0...1 multiplier on the configured brightness.
    private(set) var amplitude: [Float]
    /// Multiplier (≥ 1) on the glow's falloff length.
    private(set) var width: [Float]
    /// Each cell's left-to-right position (0...1), for stereo.
    var horizontalFraction: [Float]

    private var time: Double = 0
    private var flowPhase: Double = 0
    private var wobblePhase: Double = 0
    private var envelope: Float = 0
    private var heldBeat: Float = 0
    private var musicMix: Float = 0
    private var stereoLeft: Float = 1
    private var stereoRight: Float = 1
    private var history: [(time: Double, value: Float)] = []
    private var historyStart = 0
    /// When the swell last changed fast, for the frame rate.
    private var lastFastMusic = -Double.infinity

    private var fromPalette: GlowPalette
    private var toPalette: GlowPalette
    private var paletteProgress: Double = 1
    /// Opening sweep progress, 0...1; 1 when not playing.
    private var introProgress: Double = 1

    private var accent: GlowAccent
    private var ring = TimerRing()

    /// Where the opening sweep and accents start: the middle of the bottom edge, as a position
    /// around the screen. Set from the screen's geometry.
    var introOrigin: Double = 0.625
    /// Where the timer ring starts: the middle of the top edge. Set from the screen's geometry.
    var ringOrigin: Double = 0.125
    /// Per-cell color field, and scratch space for finding the balance threshold.
    private var colorField: [Float]
    private var selectionScratch: [Float]
    /// Per cell, cos and sin of 1, 2 and 3 times its angle around the screen: every per-cell wave
    /// is then a few multiply-adds instead of a cosine.
    private let harmonics: [SIMD8<Float>]
    /// The envelope as it was `index × envelopeDelayStep` seconds ago, for this frame.
    private var delayedEnvelope: [Float] = []
    private let envelopeDelayStep = 1.0 / 240

    init(palette: GlowPalette = .fallback) {
        red = Array(repeating: 0, count: count)
        green = red
        blue = red
        amplitude = Array(repeating: 1, count: count)
        width = amplitude
        horizontalFraction = Array(repeating: 0.5, count: count)
        colorField = Array(repeating: 0, count: count)
        selectionScratch = colorField
        let cells = count
        harmonics = (0..<cells).map { i in
            let a = 2 * Double.pi * Double(i) / Double(cells)
            return SIMD8<Float>(
                Float(cos(a)), Float(sin(a)), Float(cos(2 * a)), Float(sin(2 * a)),
                Float(cos(3 * a)), Float(sin(3 * a)), 0, 0
            )
        }
        accent = GlowAccent(count: cells)
        fromPalette = palette
        toPalette = palette
        history.reserveCapacity(256)
    }

    var palette: GlowPalette { toPalette }

    /// Whether another frame would look different: false only when holding still with nothing
    /// changing, so the display link can stop.
    func needsFrames(_ settings: GlowMotionSettings, audioActive: Bool) -> Bool {
        frameRate(settings, audioActive: audioActive) > 0
    }

    /// Frames per second needed for everything that's moving to look smooth; 0 when holding
    /// still. Fast swells get the full rate, the slow flow and fades much less, and a timer ring
    /// alone only as many as it takes to move about a point per frame.
    func frameRate(_ settings: GlowMotionSettings, audioActive: Bool) -> Double {
        let config = GlowMotionConfig.self
        let moving = settings.animation != .steady && !settings.reduceMotion
        var rate: Double = 0
        if introProgress < 1 {
            rate = settings.reduceMotion ? config.fadeFrameRate : config.fastMusicFrameRate
        }
        if paletteProgress < 1 || (musicMix > 0.001 && musicMix < 0.999) {
            rate = max(rate, config.fadeFrameRate)
        }
        let music = settings.animation == .musicSync && audioActive
        if music {
            let fast = time - lastFastMusic < config.fastMusicHoldSeconds
            rate = max(rate, fast ? config.fastMusicFrameRate : config.slowMusicFrameRate)
        } else if musicMix > 0.001 || envelope > 0.001 {
            rate = max(rate, config.fadeFrameRate)
        }
        if moving {
            let flow = config.flowFrameRate * settings.flowSpeed
            rate = max(rate, min(max(flow, config.flowFrameRateRange.lowerBound), config.flowFrameRateRange.upperBound))
        }
        rate = max(rate, accent.frameRate(moving: moving || music))
        return max(rate, ring.frameRate(perimeter: perimeterPoints ?? 5000))
    }

    /// Plays the opening sweep from the start.
    func startIntro() {
        introProgress = 0
    }

    /// Sweeps `palette` in over the light, lets it flow for a while, then fades back to the
    /// current palette. Starting another restarts it.
    func playAccent(_ palette: GlowPalette) {
        accent.start(palette)
    }

    /// Shows a timer ring with `fraction` (0...1) of the perimeter lit; nil removes it.
    func setTimerRing(_ fraction: Double?) {
        ring.set(fraction)
    }

    /// Plays the finish pulses and ends the ring.
    func playTimerFinished() {
        ring.finish()
    }

    /// Puts the ring where it's heading without easing, after time passed unseen.
    func settleTimerRing() {
        ring.settle()
    }

    /// The timer ring's shown remaining share (nil without a ring) — for tests.
    var shownTimerRing: Double? { ring.shown }

    func setPalette(_ palette: GlowPalette, animated: Bool) {
        guard palette != toPalette else { return }
        fromPalette = animated ? displayedPalette : palette
        toPalette = palette
        paletteProgress = animated ? 0 : 1
    }

    /// Advances by `dt` seconds and recomputes every cell. `audio` is nil outside Music Sync.
    func step(dt: Double, audio: AudioAnalysisState?, settings: GlowMotionSettings) {
        let dt = min(max(dt, 0), 0.1)
        time += dt
        let config = GlowMotionConfig.self
        let moving = settings.animation != .steady && !settings.reduceMotion
        let audioActive = audio.map { $0.hasAudio && !$0.isSilent } ?? false

        // Envelope: beats and bass become a swell with a quick rise and a slow fall.
        var target: Float = 0
        if let audio, audioActive {
            let bass = max(audio.bass - config.bassThreshold, 0) / (1 - config.bassThreshold)
            heldBeat = max(audio.beatPulse, heldBeat * Float(exp(-dt / config.beatHoldSeconds)))
            target = min(config.beatWeight * heldBeat + config.bassWeight * bass, 1)
            let louder = max(audio.leftEnergy, audio.rightEnergy) + 0.02
            stereoLeft = approach(stereoLeft, (audio.leftEnergy + 0.02) / louder, seconds: 0.15, dt: dt)
            stereoRight = approach(stereoRight, (audio.rightEnergy + 0.02) / louder, seconds: 0.15, dt: dt)
        } else {
            heldBeat = 0
            stereoLeft = approach(stereoLeft, 1, seconds: 0.5, dt: dt)
            stereoRight = approach(stereoRight, 1, seconds: 0.5, dt: dt)
        }
        let seconds = target > envelope ? config.envelopeAttackSeconds : config.envelopeReleaseSeconds
        let before = envelope
        envelope = approach(envelope, target, seconds: seconds, dt: dt)
        if dt > 0, abs(envelope - before) > config.fastMusicRate * Float(dt) { lastFastMusic = time }
        record(envelope)
        musicMix = approach(musicMix, audioActive ? 1 : 0, linearSeconds: config.musicBlendSeconds, dt: dt)

        if moving {
            let boost = 1 + config.musicFlowBoost * Double(envelope * musicMix)
            flowPhase += dt / config.flowLapSeconds * settings.flowSpeed * boost
            wobblePhase += dt / config.wobbleSeconds
        }
        if paletteProgress < 1 {
            paletteProgress = min(paletteProgress + dt / config.paletteFadeSeconds, 1)
        }
        if introProgress < 1 {
            introProgress = min(introProgress + dt / config.introSeconds, 1)
        }
        accent.advance(dt: dt, origin: introOrigin, sweeping: !settings.reduceMotion)
        ring.advance(dt: dt, perimeter: perimeterPoints ?? 5000)

        fill(settings: settings, moving: moving)
        if accent.isActive { applyAccent() }
        if introProgress < 1 { applyIntro(sweeping: !settings.reduceMotion) }
        ring.apply(amplitude: &amplitude, width: &width, origin: ringOrigin)
    }

    // MARK: - Fields

    private var displayedPalette: GlowPalette {
        let t = smoothstep(0, 1, paletteProgress)
        return GlowPalette(
            primary: fromPalette.primary.mixed(with: toPalette.primary, fraction: t),
            secondary: fromPalette.secondary.mixed(with: toPalette.secondary, fraction: t),
            balance: fromPalette.balance + (toPalette.balance - fromPalette.balance) * t
        )
    }

    private func fill(settings: GlowMotionSettings, moving: Bool) {
        let config = GlowMotionConfig.self
        let palette = displayedPalette
        let p = (Float(palette.primary.red), Float(palette.primary.green), Float(palette.primary.blue))
        let s = (Float(palette.secondary.red), Float(palette.secondary.green), Float(palette.secondary.blue))
        let softness = config.colorSoftness

        let reactivity = settings.reactivity
        let floor = min(max(1 - (1 - config.musicFloor) * reactivity, 0.03), 1)
        let widthGain = config.musicWidthGain * reactivity
        let breath = 1 - config.idleBreathDepth * 0.5 * (1 - Float(cos(2 * .pi * time / config.idleBreathSeconds)))
        let mix = musicMix
        let stereo = settings.stereo && settings.animation == .musicSync
        let still = settings.animation == .steady || !moving

        // Every per-cell wave is cos(k·θ + φ) for the cell's angle θ, expanded as
        // cos(kθ)·cos φ − sin(kθ)·sin φ with this frame's phases φ worked out once, here.
        let flow = 2 * Double.pi * flowPhase
        let wobble = wobblePhase * 2 * .pi
        func wave(_ phase: Double, weight: Double) -> (cos: Float, sin: Float) {
            (Float(weight * cos(phase)), Float(weight * sin(phase)))
        }
        // Color field: broad blobs, sliding with the flow and slowly changing shape. The primary
        // takes the cells above the field's (1 − balance) quantile, so it covers `balance` of the
        // edge whatever shape the blobs currently have.
        let field1 = wave(flow, weight: 0.62)
        let field2 = wave(2 * flow + wobble, weight: 0.25)
        let field3 = wave(3 * flow - 1.7 * wobble + 1, weight: 0.13)
        // Idle: soft brighter and dimmer patches drifting a little slower than the colors.
        let patchFlow = 0.8 * flow
        let patch2 = wave(2 * patchFlow - 0.8 * wobble + 2, weight: 0.6)
        let patch3 = wave(3 * patchFlow + 1.3 * wobble, weight: 0.4)

        for i in 0..<count {
            let h = harmonics[i]
            colorField[i] = field1.cos * h[0] - field1.sin * h[1] + field2.cos * h[2] - field2.sin * h[3]
                + field3.cos * h[4] - field3.sin * h[5]
        }
        let threshold = balanceThreshold(Float(min(max(palette.balance, 0), 1)))

        // Swells start at the origins, which drift with the colors, and travel outward both ways.
        let travels = moving && perimeterPoints != nil
        let origins = config.swellOrigins.map { origin in
            let shifted = origin - flowPhase
            return shifted - shifted.rounded(.down)
        }
        let delaySteps = (perimeterPoints ?? 0) / config.swellSpeed / envelopeDelayStep
        if mix > 0, travels { resampleEnvelope(steps: 0.5 * delaySteps) }
        let cells = count
        let envelope = envelope
        let stereoLeft = stereoLeft, stereoRight = stereoRight

        // Straight through buffers: this runs for every cell, every frame.
        harmonics.withUnsafeBufferPointer { harmonics in
        colorField.withUnsafeBufferPointer { colorField in
        red.withUnsafeMutableBufferPointer { red in
        green.withUnsafeMutableBufferPointer { green in
        blue.withUnsafeMutableBufferPointer { blue in
        amplitude.withUnsafeMutableBufferPointer { amplitude in
        width.withUnsafeMutableBufferPointer { width in
            for i in 0..<cells {
                let h = harmonics[i]
                let primaryShare = smoothstep(threshold - softness, threshold + softness, colorField[i])
                red[i] = s.0 + (p.0 - s.0) * primaryShare
                green[i] = s.1 + (p.1 - s.1) * primaryShare
                blue[i] = s.2 + (p.2 - s.2) * primaryShare

                let patch = 0.5 + 0.5 * (patch2.cos * h[2] - patch2.sin * h[3] + patch3.cos * h[4] - patch3.sin * h[5])
                let idleAmplitude = (1 - config.idlePatchDepth + config.idlePatchDepth * patch) * breath
                let idleWidth = 1 + config.idleWidthDepth * (patch - 0.5)

                var musicAmplitude: Float = 0
                var musicWidth: Float = 1
                if mix > 0 {
                    // The envelope as it arrives here, fading a little as it goes. Without
                    // motion, every point sees it at once.
                    var swell = envelope
                    if travels {
                        let position = Double(i) / Double(cells)
                        var nearest = 1.0
                        for origin in origins {
                            let distance = abs(position - origin)
                            nearest = min(nearest, distance, 1 - distance)
                        }
                        let fade = 1 - config.swellTravelFade * Float(min(nearest / 0.25, 1))
                        swell = delayedEnvelope(steps: nearest * delaySteps) * fade
                    }
                    var level = floor + (1 - floor) * swell * (0.8 + 0.2 * patch)
                    if stereo {
                        let x = horizontalFraction[i]
                        level *= max(stereoLeft + (stereoRight - stereoLeft) * x, config.stereoFloor)
                    }
                    musicAmplitude = level
                    musicWidth = 1 + widthGain * swell
                }

                // Holding still shows the plain glow; otherwise the idle flow, blended toward the
                // music swells while music plays.
                let restAmplitude: Float = still ? 1 : idleAmplitude
                let restWidth: Float = still ? 1 : idleWidth
                amplitude[i] = restAmplitude + (musicAmplitude - restAmplitude) * mix
                width[i] = max(restWidth + (musicWidth - restWidth) * mix, 1)
            }
        }}}}}}}
    }

    /// The accent's colors over the computed ones, cell by cell (over the accent it replaced, if
    /// it's still sweeping in), plus its head.
    private func applyAccent() {
        guard let palette = accent.palette else { return }
        let softness = GlowMotionConfig.colorSoftness
        func colors(_ palette: GlowPalette) -> (threshold: Float, primary: SIMD3<Float>, secondary: SIMD3<Float>) {
            (
                balanceThreshold(Float(min(max(palette.balance, 0), 1))),
                SIMD3(Float(palette.primary.red), Float(palette.primary.green), Float(palette.primary.blue)),
                SIMD3(Float(palette.secondary.red), Float(palette.secondary.green), Float(palette.secondary.blue))
            )
        }
        let current = colors(palette)
        let previous = accent.previous.map(colors)
        for i in 0..<count {
            var color = SIMD3(red[i], green[i], blue[i])
            if let previous, accent.previousShare[i] > 0 {
                let share = smoothstep(previous.threshold - softness, previous.threshold + softness, colorField[i])
                let accentColor = previous.secondary + (previous.primary - previous.secondary) * share
                color += (accentColor - color) * accent.previousShare[i]
            }
            let mix = accent.share[i]
            if mix > 0 {
                let share = smoothstep(current.threshold - softness, current.threshold + softness, colorField[i])
                let accentColor = current.secondary + (current.primary - current.secondary) * share
                color += (accentColor - color) * mix
            }
            red[i] = color.x
            green[i] = color.y
            blue[i] = color.z
            let head = accent.head[i]
            if head > 0 {
                amplitude[i] = min(amplitude[i] + head, 1)
                width[i] += head
            }
        }
    }

    /// The opening sweep over the computed cells: everything beyond the two fronts is dark, a
    /// bright, slightly wider head leads each front, and the head fades as the light settles.
    /// With Reduce Motion it's a plain fade-in.
    private func applyIntro(sweeping: Bool) {
        let config = GlowMotionConfig.self
        guard sweeping else {
            let fade = Float(smoothstep(0, 1, introProgress))
            for i in 0..<count { amplitude[i] *= fade }
            return
        }
        let softness = config.introEdgeSoftness
        let settle = max((introProgress - config.introSweepShare) / (1 - config.introSweepShare), 0)
        let front = EdgeSweep.front(introProgress / config.introSweepShare, settle: settle, softness: softness)
        let headStrength = config.introHeadBoost * Float(1 - smoothstep(0, 1, settle))
        for i in 0..<count {
            let distance = EdgeSweep.distance(Double(i) / Double(count), introOrigin)
            let cell = EdgeSweep.cell(distance: distance, front: front, softness: softness)
            let head = headStrength * cell.head
            amplitude[i] = min(amplitude[i] * cell.lit + head, 1)
            width[i] += head
        }
    }

    /// Perimeter in points, set from the screen geometry so swells travel at a real speed.
    var perimeterPoints: Double?

    /// The color-field value below which a `1 − balance` share of cells falls. Past either end
    /// it moves beyond the field's range, so one color fills the whole edge.
    private func balanceThreshold(_ balance: Float) -> Float {
        if balance >= 0.999 { return -.greatestFiniteMagnitude / 2 }
        if balance <= 0.001 { return .greatestFiniteMagnitude / 2 }
        let rank = min(max(Int((1 - balance) * Float(count)), 0), count - 1)
        let cells = count
        return selectionScratch.withUnsafeMutableBufferPointer { scratch in
            colorField.withUnsafeBufferPointer { field in
                scratch.baseAddress!.update(from: field.baseAddress!, count: cells)
            }
            return Self.select(rank, in: scratch)
        }
    }

    /// The `rank`-th smallest of `values` (Hoare's quickselect), reordering them on the way.
    private static func select(_ rank: Int, in values: UnsafeMutableBufferPointer<Float>) -> Float {
        var low = 0, high = values.count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low, j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if rank <= j {
                high = j
            } else if rank >= i {
                low = i
            } else {
                break
            }
        }
        return values[rank]
    }

    // MARK: - Envelope history

    private func record(_ value: Float) {
        history.append((time, value))
        // Drop what's older than any delay can reach; compact occasionally instead of per frame.
        while historyStart < history.count, history[historyStart].time < time - GlowMotionConfig.historySeconds {
            historyStart += 1
        }
        if historyStart > 128 {
            history.removeFirst(historyStart)
            historyStart = 0
        }
    }

    /// Samples the envelope history every `envelopeDelayStep` back from now, `steps` deep, so each
    /// cell's delayed envelope is one interpolation instead of a search.
    private func resampleEnvelope(steps: Double) {
        let needed = Int(steps) + 2
        if delayedEnvelope.count != needed { delayedEnvelope = Array(repeating: envelope, count: needed) }
        guard historyStart < history.count else {
            for k in 0..<needed { delayedEnvelope[k] = envelope }
            return
        }
        // Each sample is further back, so the search only ever moves back through the history.
        var index = history.count - 1
        for k in 0..<needed {
            let when = time - Double(k) * envelopeDelayStep
            if when <= history[historyStart].time {
                delayedEnvelope[k] = history[historyStart].value
                continue
            }
            while index > historyStart, history[index - 1].time > when { index -= 1 }
            let newer = history[index]
            let older = history[max(index - 1, historyStart)]
            guard newer.time > older.time else {
                delayedEnvelope[k] = newer.value
                continue
            }
            let t = Float((when - older.time) / (newer.time - older.time))
            delayedEnvelope[k] = older.value + (newer.value - older.value) * min(max(t, 0), 1)
        }
    }

    /// The envelope `steps` × `envelopeDelayStep` seconds ago, from this frame's samples.
    private func delayedEnvelope(steps: Double) -> Float {
        let last = delayedEnvelope.count - 1
        let index = min(Int(steps), last - 1)
        let t = Float(min(steps - Double(index), 1))
        return delayedEnvelope[index] + (delayedEnvelope[index + 1] - delayedEnvelope[index]) * t
    }

    // MARK: - Helpers

    /// One-pole approach toward `target` with time constant `seconds`.
    private func approach(_ value: Float, _ target: Float, seconds: Double, dt: Double) -> Float {
        let alpha = Float(1 - exp(-dt / max(seconds, 0.0001)))
        return value + (target - value) * alpha
    }

    /// Straight-line approach, reaching `target` from the other end in `linearSeconds`.
    private func approach(_ value: Float, _ target: Float, linearSeconds: Double, dt: Double) -> Float {
        let step = Float(dt / max(linearSeconds, 0.0001))
        return target > value ? min(value + step, target) : max(value - step, target)
    }
}

func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
