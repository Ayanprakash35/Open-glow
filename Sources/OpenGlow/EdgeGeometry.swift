import AppKit

/// Corner and notch shaping for the edge light.
enum EdgeGeometryConfig {
    /// How round, in points, the glow's corners and notch corners are. The distance from the edge
    /// is a smooth minimum over the sides (log-sum-exp), so where two sides meet the glow bends
    /// around instead of creasing along the diagonal. Sane range: 6–30.
    static let cornerSoftness: CGFloat = 10
    /// How gradually, in points, a point's position around the screen hands over from one side to
    /// the next at a corner. Wider keeps colors from bunching up in the corners. Sane range: 10–60.
    static let positionBlend: CGFloat = 32
}

/// Describes where a screen's camera-housing notch sits, in the overlay view's own coordinate
/// space (origin at the view's bottom-left, Y increasing upward — same convention as `NSScreen`,
/// since `GlowView` doesn't flip itself).
///
/// `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` are the two rectangles flanking the notch that
/// still have pixels all the way to the screen's true top edge; the notch itself sits between
/// them, with real pixels only resuming at `bottomY`. Screens without a notch report both as nil,
/// so `init?` naturally fails.
struct NotchGeometry: Equatable {
    let leftEdgeX: CGFloat
    let rightEdgeX: CGFloat
    let bottomY: CGFloat

    init?(screen: NSScreen) {
        guard let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }
        let origin = screen.frame.origin
        leftEdgeX = leftArea.maxX - origin.x
        rightEdgeX = rightArea.minX - origin.x
        bottomY = leftArea.minY - origin.y
    }

    init(leftEdgeX: CGFloat, rightEdgeX: CGFloat, bottomY: CGFloat) {
        self.leftEdgeX = leftEdgeX
        self.rightEdgeX = rightEdgeX
        self.bottomY = bottomY
    }
}

/// Where a point sits relative to the screen edge: how far in it is, and where along the edge
/// (0...1, clockwise from the top-left corner) the light reaching it comes from.
struct EdgePoint: Equatable {
    var distance: CGFloat
    var position: CGFloat
}

/// The geometry of light coming in from the screen's edges: for any point on screen, its distance
/// from the nearest edge (the notch's outline counts as edge) and its position around the screen.
/// Pure math, so it's tested directly.
struct EdgeGeometry: Equatable {
    let size: CGSize
    let notch: NotchGeometry?

    /// Perimeter of the screen rectangle, in points. Positions are fractions of this.
    var perimeter: CGFloat { 2 * (size.width + size.height) }

    /// How far the notch reaches down from the top edge (0 without one).
    var notchDepth: CGFloat {
        guard let notch, isUsable(notch) else { return 0 }
        return max(size.height - notch.bottomY, 0)
    }

    /// Runs for every cell of the glow whenever its size or shape changes, so it allocates nothing.
    func point(at p: CGPoint) -> EdgePoint {
        let w = size.width, h = size.height
        // Distance to each side, and the position along the perimeter of the nearest point on it:
        // top (left → right), right (top → bottom), bottom (right → left), left (bottom → top).
        var distances = (h - p.y, w - p.x, p.y, p.x, CGFloat.infinity)
        var positions = (clamp(p.x, 0, w), w + (h - clamp(p.y, 0, h)), w + h + (w - clamp(p.x, 0, w)), 2 * w + h + clamp(p.y, 0, h), CGFloat(0))
        if let notch, isUsable(notch) {
            // Outside distance to the notch rectangle; its outline shares positions with the top
            // edge it interrupts, so colors pass around it without a jump.
            let dx = max(notch.leftEdgeX - p.x, 0, p.x - notch.rightEdgeX)
            let dy = max(notch.bottomY - p.y, 0)
            distances.4 = hypot(dx, dy)
            positions.4 = clamp(p.x, 0, w)
        }
        return withUnsafeBytes(of: &distances) { distanceBytes in
            withUnsafeBytes(of: &positions) { positionBytes in
                let d = distanceBytes.bindMemory(to: CGFloat.self)
                let s = positionBytes.bindMemory(to: CGFloat.self)
                var nearest = CGFloat.infinity
                for i in 0..<5 { nearest = min(nearest, d[i]) }

                // Smooth minimum (log-sum-exp), shifted by the true minimum for numerical stability.
                let k = EdgeGeometryConfig.cornerSoftness
                var sum: CGFloat = 0
                for i in 0..<5 where d[i].isFinite { sum += exp(-(d[i] - nearest) / k) }
                let distance = max(nearest - k * log(sum), 0)

                // Circular weighted mean of the sides' positions, so the position hands over
                // smoothly at corners and wraps cleanly at the top-left.
                let blend = EdgeGeometryConfig.positionBlend
                var x: CGFloat = 0, y: CGFloat = 0
                for i in 0..<5 where d[i].isFinite {
                    let weight = exp(-(d[i] - nearest) / blend)
                    let angle = 2 * .pi * s[i] / perimeter
                    x += weight * cos(angle)
                    y += weight * sin(angle)
                }
                var position = atan2(y, x) / (2 * .pi)
                if position < 0 { position += 1 }
                return EdgePoint(distance: distance, position: position)
            }
        }
    }

    /// The center of the perimeter cell at `position`, back in view coordinates — used to place
    /// per-position effects (stereo balance) left or right.
    func horizontalFraction(atPosition position: CGFloat) -> CGFloat {
        let w = size.width, h = size.height
        let along = position * perimeter
        switch along {
        case ..<w: return along / w
        case ..<(w + h): return 1
        case ..<(2 * w + h): return 1 - (along - w - h) / w
        default: return 0
        }
    }

    private func isUsable(_ notch: NotchGeometry) -> Bool {
        notch.leftEdgeX > 0 && notch.rightEdgeX < size.width && notch.leftEdgeX < notch.rightEdgeX
            && notch.bottomY < size.height && notch.bottomY > 0
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}
