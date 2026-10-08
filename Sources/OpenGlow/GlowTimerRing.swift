import Foundation

/// The timer ring's look and pace.
enum TimerRingConfig {
    /// Width of each of the ring's soft ends, as a share of the way around. Sane range: 0.02–0.1.
    static let edgeSoftness: Double = 0.06
    /// Extra brightness and width of the bright head at the receding end. Sane range: 0–0.6.
    static let headBoost: Float = 0.35
    /// Length of that head, as a share of the end's softness. Sane range: 0.3–1.2.
    static let headLength: Double = 0.6
    /// Brightness of the used-up part of the edge, as a share of normal. Sane range: 0–0.15.
    static let spentLevel: Float = 0
    /// Seconds the shown ring takes to make up a gap below where the timer is (a correction) and
    /// above it (a new or cancelled timer refilling the ring). Time passing itself isn't eased:
    /// the ring recedes at the timer's own steady pace between updates. Sane ranges: 0.3–2 and
    /// 0.2–1.
    static let drainSeconds: Double = 0.8
    static let refillSeconds: Double = 0.45
    /// Points the boundary moves between redraws while only the ring changes: soft as it is, half
    /// a point between frames reads as continuous motion. Sane range: 0.25–2.
    static let frameStepPoints: Double = 0.5
    /// The ring counts as caught up within this many points of where it's heading. Sane range: 0.1–1.
    static let settlePoints: Double = 0.5
    /// Fastest the ring alone redraws, in frames per second. Sane range: 20–60.
    static let maximumFrameRate: Double = 30

    // MARK: Finish

    /// Three slow pulses of the whole edge, this many seconds apart; the flourish lasts 2.75 of
    /// them. Sane range: 0.6–1.2.
    static let pulseSeconds: Double = 0.9
    /// Brightness between pulses, as a share of normal. Sane range: 0.1–0.8.
    static let pulseTrough: Float = 0.35
    /// Extra brightness and width at each pulse's peak. Sane range: 0.2–1.
    static let pulseBoost: Float = 0.5
    /// Frames per second while the pulses play. Sane range: 20–60.
    static let pulseFrameRate: Double = 30
}

/// A visual timer on the edge light: only the remaining share of the perimeter is lit, measured
/// clockwise from the top center, with soft ends and a slightly brighter head where it recedes.
/// Colors and motion carry on inside the lit part. Each update says how fast the share is falling,
/// so between sparse updates (once a second) the ring keeps receding at that steady pace instead
/// of jumping or easing in spurts; any gap to the latest value is eased out. It starts full, and
/// refills before it goes away. When a timer finishes, three slow pulses of the whole edge replace
/// the ring.
///
/// Positions are shares of the way around the screen, clockwise from the top-left corner.
struct TimerRing {
    /// The remaining share the timer last reported; nil without a timer.
    private(set) var target: Double?
    /// How fast that share falls, per second (0 while paused), and seconds since the report.
    private var rate: Double = 0
    private var sinceUpdate: Double = 0
    /// The remaining share on screen; nil when no ring shows.
    private(set) var shown: Double?
    /// Seconds into the finish pulses; nil when they're not playing.
    private(set) var finishElapsed: Double?
    /// The ring that showed when the timer finished, fading out under the pulses.
    private var finishedRing: Double?

    var isActive: Bool { shown != nil || finishElapsed != nil }

    static var finishSeconds: Double { 2.75 * TimerRingConfig.pulseSeconds }

    /// `fraction` is the share left now; `rate` how much of it goes per second while it runs.
    mutating func set(_ fraction: Double?, rate: Double = 0) {
        target = fraction.map { min(max($0, 0), 1) }
        self.rate = target == nil ? 0 : max(rate, 0)
        sinceUpdate = 0
        if target != nil, shown == nil { shown = 1 }
    }

    /// Where the timer is now: the last report, carried on at its pace. 1 without a timer.
    private var goal: Double {
        guard let target else { return 1 }
        return max(target - rate * sinceUpdate, 0)
    }

    mutating func finish() {
        finishedRing = shown
        target = nil
        shown = nil
        finishElapsed = 0
    }

    /// Jumps to where the ring is heading, without easing — after time passed unseen.
    mutating func settle() {
        shown = target == nil ? nil : goal
    }

    mutating func advance(dt: Double, perimeter: Double) {
        if let value = shown {
            // Move with the timer, and ease out whatever gap is left on top of that.
            let gap = value - goal
            sinceUpdate += dt
            let now = goal
            let seconds = gap < 0 ? TimerRingConfig.refillSeconds : TimerRingConfig.drainSeconds
            var next = now + gap * exp(-dt / seconds)
            // Snap once caught up, so the ring can hold still — but not while it recedes, where
            // the snap would be a small jump in an otherwise even pace.
            let receding = target != nil && rate > 0 && now > 0
            if !receding, abs(next - now) * perimeter < TimerRingConfig.settlePoints { next = now }
            shown = target == nil && next >= 1 ? nil : min(max(next, 0), 1)
        }
        if let elapsed = finishElapsed {
            finishElapsed = elapsed + dt < Self.finishSeconds ? elapsed + dt : nil
            if finishElapsed == nil { finishedRing = nil }
        }
    }

    /// Frames per second the ring needs: just enough for the boundary to move about
    /// `frameStepPoints` per frame; 0 once it holds still.
    func frameRate(perimeter: Double) -> Double {
        var frames = finishElapsed != nil ? TimerRingConfig.pulseFrameRate : 0
        if let shown {
            let goal = goal
            let seconds = goal > shown ? TimerRingConfig.refillSeconds : TimerRingConfig.drainSeconds
            let moving = goal > 0 && target != nil ? rate : 0
            let pointsPerSecond = (moving + abs(goal - shown) / seconds) * perimeter
            if pointsPerSecond > 0 {
                frames = max(frames, min(max(pointsPerSecond / TimerRingConfig.frameStepPoints, 2), TimerRingConfig.maximumFrameRate))
            }
        }
        return frames
    }

    /// Masks the computed cells to the ring and plays the finish pulses over them. `origin` is the
    /// top center's position.
    func apply(amplitude: inout [Float], width: inout [Float], origin: Double) {
        guard isActive else { return }
        let count = amplitude.count
        let spent = TimerRingConfig.spentLevel
        // The finished ring fades out as the first pulse rises.
        let fading = finishElapsed.map { Float(1 - smoothstep(0, 0.5 * TimerRingConfig.pulseSeconds, $0)) } ?? 0
        let (dim, bright) = finishElapsed.map(Self.pulse) ?? (1, 0)
        for i in 0..<count {
            var along = Double(i) / Double(count) - origin
            along -= along.rounded(.down)
            var (lit, head) = shown.map { Self.cell(along: along, remaining: $0) } ?? (1, 0)
            if fading > 0, let finishedRing {
                lit *= 1 - fading * (1 - Self.cell(along: along, remaining: finishedRing).lit)
            }
            let level = (spent + (1 - spent) * lit) * dim
            amplitude[i] = min(amplitude[i] * level + head + bright, 1)
            width[i] += head + bright
        }
    }

    /// One cell `along` the way clockwise from the top center (0..<1): how lit it is, and the
    /// head's extra brightness there. The lit arc spans 0...remaining with soft ends centered on
    /// them (so the lit share is exactly `remaining`); the ends narrow as the arc nears empty or
    /// full, so neither the start nor the finish pops.
    static func cell(along: Double, remaining: Double) -> (lit: Float, head: Float) {
        if remaining >= 1 { return (1, 0) }
        if remaining <= 0 { return (0, 0) }
        let maximum = TimerRingConfig.edgeSoftness / 2
        let half = min(maximum, remaining / 2, (1 - remaining) / 2)
        var fromMiddle = along - remaining / 2
        fromMiddle -= fromMiddle.rounded()
        let lit = Float(1 - smoothstep(remaining / 2 - half, remaining / 2 + half, abs(fromMiddle)))
        var fromHead = along - (remaining - half / 2)
        fromHead -= fromHead.rounded()
        let offset = fromHead / (TimerRingConfig.headLength * half)
        let head = TimerRingConfig.headBoost * Float(half / maximum) * Float(exp(-offset * offset)) * lit
        return (lit, head)
    }

    /// The finish pulses at `elapsed` seconds: a brightness multiplier dipping between pulses, and
    /// the extra brightness of each pulse. Peaks at 0.5, 1.5 and 2.5 pulse periods; it starts
    /// rising from normal and ends settling to normal, both without a jump.
    static func pulse(_ elapsed: Double) -> (dim: Float, bright: Float) {
        let wave = Float(cos(2 * .pi * elapsed / TimerRingConfig.pulseSeconds))
        let bright = wave < 0 ? wave * wave * TimerRingConfig.pulseBoost : 0
        let dip = elapsed > 0.5 * TimerRingConfig.pulseSeconds && wave > 0 ? wave * wave : 0
        return (1 - (1 - TimerRingConfig.pulseTrough) * dip, bright)
    }
}
