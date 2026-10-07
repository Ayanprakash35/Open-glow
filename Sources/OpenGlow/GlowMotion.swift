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

    private var fromPalette: GlowPalette
    private var toPalette: GlowPalette
    private var paletteProgress: Double = 1
    /// Opening sweep progress, 0...1; 1 when not playing.
    private var introProgress: Double = 1

    /// Where the opening sweep starts: the middle of the bottom edge, as a position around the
    /// screen. Set from the screen's geometry.
    var introOrigin: Double = 0.625
    /// Per-cell color field, and a sorted copy for finding the balance threshold.
    private var colorField: [Float]
    private var sortedField: [Float]

    init(palette: GlowPalette = .fallback) {
        red = Array(repeating: 0, count: count)
        green = red
        blue = red
        amplitude = Array(repeating: 1, count: count)
        width = amplitude
        horizontalFraction = Array(repeating: 0.5, count: count)
        colorField = Array(repeating: 0, count: count)
        sortedField = colorField
        fromPalette = palette
        toPalette = palette
        history.reserveCapacity(256)
    }

    var palette: GlowPalette { toPalette }

    /// Whether another frame would look different: false only when holding still with nothing
    /// fading, so the display link can stop.
    func needsFrames(_ settings: GlowMotionSettings, audioActive: Bool) -> Bool {
        if paletteProgress < 1 || introProgress < 1 { return true }
        switch settings.animation {
        case .steady: return musicMix > 0.001 || envelope > 0.001
        case .flow: return !settings.reduceMotion || musicMix > 0.001
        case .musicSync: return audioActive || !settings.reduceMotion || musicMix > 0.001 || envelope > 0.001
        }
    }

    /// Plays the opening sweep from the start.
    func startIntro() {
        introProgress = 0
    }

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
        envelope = approach(envelope, target, seconds: seconds, dt: dt)
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

        fill(settings: settings, moving: moving)
        if introProgress < 1 { applyIntro(sweeping: !settings.reduceMotion) }
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
        let travel = moving
        let mix = musicMix
        let stereo = settings.stereo && settings.animation == .musicSync

        let flow = flowPhase
        let wobble = wobblePhase * 2 * .pi
        let still = settings.animation == .steady || !moving

        // Color field: broad blobs, sliding with the flow and slowly changing shape. The primary
        // takes the cells above the field's (1 − balance) quantile, so it covers `balance` of the
        // edge whatever shape the blobs currently have.
        for i in 0..<count {
            let a = 2 * Double.pi * (Double(i) / Double(count) + flow)
            colorField[i] = Float(0.62 * cos(a) + 0.25 * cos(2 * a + wobble) + 0.13 * cos(3 * a - 1.7 * wobble + 1))
        }
        let threshold = balanceThreshold(Float(min(max(palette.balance, 0), 1)))

        for i in 0..<count {
            let position = Double(i) / Double(count)
            let primaryShare = smoothstep(threshold - softness, threshold + softness, colorField[i])
            red[i] = s.0 + (p.0 - s.0) * primaryShare
            green[i] = s.1 + (p.1 - s.1) * primaryShare
            blue[i] = s.2 + (p.2 - s.2) * primaryShare

            // Idle: soft brighter and dimmer patches drifting a little slower than the colors.
            let b = 2 * Double.pi * (position + 0.8 * flow)
            let patch = Float(0.5 + 0.5 * (0.6 * cos(2 * b - 0.8 * wobble + 2) + 0.4 * cos(3 * b + 1.3 * wobble)))
            let idleAmplitude = (1 - config.idlePatchDepth + config.idlePatchDepth * patch) * breath
            let idleWidth = 1 + config.idleWidthDepth * (patch - 0.5)

            var musicAmplitude: Float = 0
            var musicWidth: Float = 1
            if mix > 0 {
                let swell = travelledEnvelope(at: position, flow: flow, travel: travel)
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
        // Fronts ease out as they climb; both reach the top (half way around) together.
        let sweep = min(introProgress / config.introSweepShare, 1)
        let front = 0.5 * (1 - pow(1 - sweep, 2.2))
        let settle = max((introProgress - config.introSweepShare) / (1 - config.introSweepShare), 0)
        let headStrength = config.introHeadBoost * Float(1 - smoothstep(0, 1, settle))
        let softness = config.introEdgeSoftness
        for i in 0..<count {
            let position = Double(i) / Double(count)
            var distance = abs(position - introOrigin)
            distance = min(distance, 1 - distance)
            let lit = Float(1 - smoothstep(front - softness, front + softness, distance))
            let offset = (distance - front) / (softness * 1.6)
            let head = headStrength * Float(exp(-offset * offset)) * lit
            amplitude[i] = min(amplitude[i] * lit + head, 1)
            width[i] += head
        }
    }

    /// The envelope as it arrives at `position`: swells start at the origins and travel outward
    /// both ways, fading a little as they go. Without motion, every point sees it at once.
    private func travelledEnvelope(at position: Double, flow: Double, travel: Bool) -> Float {
        guard travel, let perimeter = perimeterPoints else { return envelope }
        var nearest = 1.0
        for origin in GlowMotionConfig.swellOrigins {
            // The origins drift with the colors; distance is measured around the loop.
            let shifted = origin - flow
            let wrapped = shifted - shifted.rounded(.down)
            let distance = abs(position - wrapped)
            nearest = min(nearest, distance, 1 - distance)
        }
        let delay = nearest * perimeter / GlowMotionConfig.swellSpeed
        let fade = 1 - GlowMotionConfig.swellTravelFade * Float(min(nearest / 0.25, 1))
        return envelopeAt(time - delay) * fade
    }

    /// Perimeter in points, set from the screen geometry so swells travel at a real speed.
    var perimeterPoints: Double?

    /// The color-field value below which a `1 − balance` share of cells falls. Past either end
    /// it moves beyond the field's range, so one color fills the whole edge.
    private func balanceThreshold(_ balance: Float) -> Float {
        if balance >= 0.999 { return -.greatestFiniteMagnitude / 2 }
        if balance <= 0.001 { return .greatestFiniteMagnitude / 2 }
        sortedField.withUnsafeMutableBufferPointer { sorted in
            colorField.withUnsafeBufferPointer { field in
                sorted.baseAddress!.update(from: field.baseAddress!, count: count)
            }
            sorted.sort()
        }
        let index = min(max(Int((1 - balance) * Float(count)), 0), count - 1)
        return sortedField[index]
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

    private func envelopeAt(_ when: Double) -> Float {
        guard historyStart < history.count else { return envelope }
        if when <= history[historyStart].time { return history[historyStart].value }
        // Newest first: most lookups are recent.
        var index = history.count - 1
        while index > historyStart, history[index - 1].time > when { index -= 1 }
        let newer = history[index]
        let older = history[max(index - 1, historyStart)]
        guard newer.time > older.time else { return newer.value }
        let t = Float((when - older.time) / (newer.time - older.time))
        return older.value + (newer.value - older.value) * min(max(t, 0), 1)
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
