import Foundation

/// A sweep racing from one point around both sides of the screen until the two fronts meet
/// opposite it, led by a bright head — the shape of the opening and of an accent.
enum EdgeSweep {
    /// How far each front has travelled, as a share of the way around: easing out to the meeting
    /// point as `progress` goes 0...1, then on past it by `softness` as `settle` goes 0...1, so
    /// the meeting point fills in too instead of popping when the sweep ends.
    static func front(_ progress: Double, settle: Double, softness: Double) -> Double {
        0.5 * (1 - pow(1 - min(max(progress, 0), 1), 2.2)) + softness * smoothstep(0, 1, settle)
    }

    /// For a cell `distance` around from the origin (0...0.5): how lit it is (0...1), and the
    /// head's profile there (0...1, peaking just behind the front).
    static func cell(distance: Double, front: Double, softness: Double) -> (lit: Float, head: Float) {
        let lit = Float(1 - smoothstep(front - softness, front + softness, distance))
        let offset = (distance - front) / (softness * 1.6)
        return (lit, Float(exp(-offset * offset)) * lit)
    }

    /// Distance around the loop between two positions (0...0.5).
    static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }
}

/// An accent: another palette that briefly takes over the light. It sweeps in from the opening's
/// origin over the current glow, flows for `GlowMotionConfig.accentHoldSeconds`, then cross-fades
/// back to whatever the current palette is by then. With Reduce Motion it's a plain cross-fade in
/// and back. Starting one while another shows sweeps the new one in over it.
///
/// This only tracks time and per-cell shares; `GlowMotion` mixes the colors.
struct GlowAccent {
    /// The accent showing, nil when none is.
    private(set) var palette: GlowPalette?
    /// The accent that was showing when this one started, and how much of it each cell showed.
    private(set) var previous: GlowPalette?
    private(set) var previousShare: [Float]
    /// How much of `palette` each cell shows, 0...1.
    private(set) var share: [Float]
    /// The sweep's head: extra brightness and width per cell.
    private(set) var head: [Float]
    private var elapsed: Double = 0

    init(count: Int) {
        share = Array(repeating: 0, count: count)
        previousShare = share
        head = share
    }

    var isActive: Bool { palette != nil }

    mutating func start(_ palette: GlowPalette) {
        if self.palette != nil {
            previous = self.palette
            previousShare = share
        } else {
            previous = nil
        }
        self.palette = palette
        elapsed = 0
    }

    /// Advances by `dt` seconds and recomputes the shares. `origin` is where the sweep starts
    /// (a position around the screen); without `sweeping` it fades in evenly.
    mutating func advance(dt: Double, origin: Double, sweeping: Bool) {
        guard palette != nil else { return }
        let config = GlowMotionConfig.self
        elapsed += dt
        let fadeStart = config.accentSweepSeconds + config.accentHoldSeconds
        if elapsed >= fadeStart + config.accentFadeSeconds {
            palette = nil
            previous = nil
            fill(share: 0)
            return
        }
        if elapsed >= fadeStart {
            fill(share: Float(1 - smoothstep(0, 1, (elapsed - fadeStart) / config.accentFadeSeconds)))
            return
        }
        guard sweeping else {
            fill(share: Float(smoothstep(0, 1, elapsed / config.accentFadeSeconds)))
            return
        }
        let softness = config.introEdgeSoftness
        let settle = max(elapsed - config.accentSweepSeconds, 0) / config.accentSettleSeconds
        let front = EdgeSweep.front(elapsed / config.accentSweepSeconds, settle: settle, softness: softness)
        let strength = config.accentHeadBoost * Float(1 - smoothstep(0, 1, settle))
        let count = share.count
        for i in 0..<count {
            let cell = EdgeSweep.cell(
                distance: EdgeSweep.distance(Double(i) / Double(count), origin), front: front, softness: softness
            )
            share[i] = cell.lit
            head[i] = strength * cell.head
        }
        if settle >= 1 { previous = nil }
    }

    /// Frames per second the accent needs: a fast sweep, a slow cross-fade, and while it only
    /// flows, nothing of its own (a few frames a second when nothing else moves, to notice the
    /// fade's start).
    func frameRate(moving: Bool) -> Double {
        guard palette != nil else { return 0 }
        let config = GlowMotionConfig.self
        if elapsed < config.accentSweepSeconds + config.accentSettleSeconds, head.contains(where: { $0 > 0.001 }) {
            return 60
        }
        let fadeStart = config.accentSweepSeconds + config.accentHoldSeconds
        let fading = elapsed >= fadeStart || share.contains { $0 < 0.999 }
        return fading ? 30 : (moving ? 0 : 2)
    }

    private mutating func fill(share value: Float) {
        for i in share.indices {
            share[i] = value
            head[i] = 0
        }
        if value >= 1 { previous = nil }
    }
}
