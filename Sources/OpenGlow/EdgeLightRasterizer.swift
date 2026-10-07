import AppKit

/// Shape and resolution of the edge light.
enum EdgeLightConfig {
    /// The glow's long, faint tail, as a multiple of Thickness (the main falloff length).
    /// Sane range: 1.5–4.
    static let tailLengthFactor: Float = 2.6
    /// The light is computed on a grid of cells this many to a falloff length, then smoothly
    /// scaled up — finer is sharper and costs more per frame. Sane range: 2.5–6.
    static let cellsPerFalloff: CGFloat = 3.6
    /// Smallest cell, in points. Sane range: 1.5–4.
    static let minimumCellSize: CGFloat = 2.5
    /// Light fainter than this share of full is cut off; that sets how far inward the strips
    /// reach. A smooth taper hides the cut. Sane range: 0.01–0.05.
    static let cutoff: Float = 0.025
    /// Distance resolution of the falloff table, in points.
    static let distanceStep: Float = 0.5
    /// Glow widths the falloff table holds, spanning 1× to the widest swell.
    static let widthBuckets = 40
}

/// Turns `GlowMotion`'s per-cell colors, brightness and widths into pixels: light coming in from
/// the screen edge, brightest at the edge and falling off smoothly inward.
///
/// Only the border can ever be lit, so the light is computed in four strips — top (tall enough
/// to wrap the notch), bottom, left and right — at a cell size a few to a falloff length, and
/// Core Animation scales each strip up with linear filtering. Every cell's distance from the edge
/// and position around the screen are worked out once per size or shape change (`EdgeGeometry`);
/// a frame is then, per cell, one table lookup and two integer multiplies.
///
/// The falloff is two exponentials — a main one (Thickness) and a faint tail (Softness sets its
/// share) — so the edge reads as a line of light with a soft bloom, never a band with a hard
/// inner edge.
@MainActor
final class EdgeLightRasterizer {
    struct Strip {
        /// Where the strip sits, in the view's points.
        let frame: CGRect
        let columns: Int
        let rows: Int
        /// Per cell, top row first: index into the motion's cells, or `unlit`.
        let position: [UInt16]
        /// Per cell: distance from the edge in `distanceStep`s.
        let distance: [UInt16]
        let context: CGContext
    }

    static let unlit = UInt16.max

    struct Shape: Equatable {
        static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        var size: CGSize
        var notch: NotchGeometry?
        /// Main falloff length in points.
        var falloff: CGFloat
        /// Share of the light in the long tail, 0...1.
        var softness: Float
        /// Widest the glow can get (multiplier on `falloff`).
        var maximumWidth: Float
        /// The display's own color space. Strips drawn in it are shown as they are; in any other
        /// space Core Animation color-matches every new frame on the CPU.
        var colorSpace: CGColorSpace = Shape.sRGB
    }

    private(set) var strips: [Strip] = []
    private(set) var shape: Shape?
    private var table: [Float] = []
    /// `table` in 8.8 fixed point (0...256), for the per-pixel integer path.
    private var fixedTable: [UInt16] = []
    private var distanceSteps = 1
    private var bucketOfCell: [Int32] = []
    private var packedColor: [UInt32] = []

    /// Rebuilds the cell tables for `shape` if it changed. Returns whether it did.
    @discardableResult
    func configure(_ shape: Shape, cells: Int) -> Bool {
        guard shape != self.shape, shape.size.width > 0, shape.size.height > 0 else { return false }
        self.shape = shape
        buildTable(shape)
        buildStrips(shape, cells: cells)
        bucketOfCell = Array(repeating: 0, count: cells)
        packedColor = Array(repeating: 0, count: cells)
        return true
    }

    /// How far inward, in points, light can reach at the widest swell.
    static func reach(falloff: CGFloat, softness: Float, maximumWidth: Float) -> CGFloat {
        let widest = Float(falloff) * maximumWidth
        let cutoff = EdgeLightConfig.cutoff
        let main = widest * log(max(1 - softness, cutoff) / cutoff)
        let tail = softness > cutoff ? widest * EdgeLightConfig.tailLengthFactor * log(softness / cutoff) : 0
        return CGFloat(max(main, tail, 1))
    }

    /// Renders the current motion state into one image per strip.
    func render(_ motion: GlowMotion, brightness: Float) -> [CGImage?] {
        guard let shape else { return [] }
        let buckets = EdgeLightConfig.widthBuckets
        let span = max(shape.maximumWidth - 1, 0.0001)
        // Per perimeter cell: its full-strength premultiplied color, packed as the bytes R, G, B,
        // A in memory, and where its width's falloff row starts in the table.
        motion.width.withUnsafeBufferPointer { width in
        motion.amplitude.withUnsafeBufferPointer { amplitude in
        motion.red.withUnsafeBufferPointer { red in
        motion.green.withUnsafeBufferPointer { green in
        motion.blue.withUnsafeBufferPointer { blue in
        packedColor.withUnsafeMutableBufferPointer { packed in
        bucketOfCell.withUnsafeMutableBufferPointer { bucket in
            for i in 0..<min(width.count, bucket.count) {
                let b = Int(((width[i] - 1) / span * Float(buckets - 1)).rounded())
                bucket[i] = Int32(min(max(b, 0), buckets - 1) * distanceSteps)
                let alpha = min(max(amplitude[i] * brightness, 0), 1)
                let r = UInt32(min(max(red[i], 0), 1) * alpha * 255 + 0.5)
                let g = UInt32(min(max(green[i], 0), 1) * alpha * 255 + 0.5)
                let b8 = UInt32(min(max(blue[i], 0), 1) * alpha * 255 + 0.5)
                let a = UInt32(alpha * 255 + 0.5)
                packed[i] = r | g << 8 | b8 << 16 | a << 24
            }
        }}}}}}}
        return strips.map(draw)
    }

    /// One strip: per cell, the perimeter cell's packed color scaled by the falloff at the
    /// cell's distance — two integer multiplies scale all four channels at once.
    private func draw(_ strip: Strip) -> CGImage? {
        guard let data = strip.context.data else { return nil }
        let wordsPerRow = strip.context.bytesPerRow / 4
        let pixels = data.bindMemory(to: UInt32.self, capacity: strip.rows * wordsPerRow)
        let unlit = Self.unlit
        packedColor.withUnsafeBufferPointer { color in
        bucketOfCell.withUnsafeBufferPointer { bucket in
        fixedTable.withUnsafeBufferPointer { table in
        strip.position.withUnsafeBufferPointer { position in
        strip.distance.withUnsafeBufferPointer { distance in
            for row in 0..<strip.rows {
                let out = pixels + row * wordsPerRow
                let cellRow = row * strip.columns
                for column in 0..<strip.columns {
                    let cell = cellRow + column
                    let p = position[cell]
                    guard p != unlit else {
                        out[column] = 0
                        continue
                    }
                    let index = Int(p)
                    // Falloff in 0...256 (8.8 fixed point).
                    let scale = UInt32(table[Int(bucket[index]) + Int(distance[cell])])
                    let packed = color[index]
                    let redBlue = ((packed & 0x00FF_00FF) &* scale) >> 8 & 0x00FF_00FF
                    let greenAlpha = ((packed >> 8) & 0x00FF_00FF) &* scale & 0xFF00_FF00
                    out[column] = redBlue | greenAlpha
                }
            }
        }}}}}
        return strip.context.makeImage()
    }

    // MARK: - Setup

    /// Falloff for every width bucket and distance step, tapered to zero at the reach.
    private func buildTable(_ shape: Shape) {
        let reach = Float(Self.reach(falloff: shape.falloff, softness: shape.softness, maximumWidth: shape.maximumWidth))
        let step = EdgeLightConfig.distanceStep
        distanceSteps = max(Int((reach / step).rounded(.up)) + 1, 2)
        let buckets = EdgeLightConfig.widthBuckets
        table = Array(repeating: 0, count: buckets * distanceSteps)
        let softness = min(max(shape.softness, 0), 1)
        for b in 0..<buckets {
            let width = 1 + (shape.maximumWidth - 1) * Float(b) / Float(max(buckets - 1, 1))
            let main = Float(shape.falloff) * width
            let tail = main * EdgeLightConfig.tailLengthFactor
            for d in 0..<distanceSteps {
                let distance = Float(d) * step
                let light = (1 - softness) * exp(-distance / main) + softness * exp(-distance / tail)
                // Fade the last fifth of the reach to zero so the strips' inner edge never shows.
                let taper = 1 - smoothstep(reach * 0.8, reach, distance)
                table[b * distanceSteps + d] = light * taper
            }
        }
        fixedTable = table.map { UInt16(min(max($0, 0), 1) * 256 + 0.5) }
    }

    private func buildStrips(_ shape: Shape, cells: Int) {
        let geometry = EdgeGeometry(size: shape.size, notch: shape.notch)
        let reach = Self.reach(falloff: shape.falloff, softness: shape.softness, maximumWidth: shape.maximumWidth)
        let cellSize = max(shape.falloff / EdgeLightConfig.cellsPerFalloff, EdgeLightConfig.minimumCellSize)
        let w = shape.size.width, h = shape.size.height
        let topHeight = min(reach + geometry.notchDepth, h / 2)
        let bottomHeight = min(reach, h / 2)
        let sideWidth = min(reach, w / 2)
        let sideHeight = max(h - topHeight - bottomHeight, 0)
        let frames = [
            CGRect(x: 0, y: h - topHeight, width: w, height: topHeight),
            CGRect(x: 0, y: 0, width: w, height: bottomHeight),
            CGRect(x: 0, y: bottomHeight, width: sideWidth, height: sideHeight),
            CGRect(x: w - sideWidth, y: bottomHeight, width: sideWidth, height: sideHeight),
        ]
        let step = CGFloat(EdgeLightConfig.distanceStep)
        let reachSteps = Int(reach / step)
        strips = frames.compactMap { frame in
            guard frame.width >= 1, frame.height >= 1 else { return nil }
            let columns = max(Int((frame.width / cellSize).rounded(.up)), 1)
            let rows = max(Int((frame.height / cellSize).rounded(.up)), 1)
            let cellWidth = frame.width / CGFloat(columns)
            let cellHeight = frame.height / CGFloat(rows)
            var position = [UInt16](repeating: Self.unlit, count: columns * rows)
            var distance = [UInt16](repeating: 0, count: columns * rows)
            for row in 0..<rows {
                // Image rows run top to bottom; the view's Y runs upward.
                let y = frame.maxY - (CGFloat(row) + 0.5) * cellHeight
                for column in 0..<columns {
                    let x = frame.minX + (CGFloat(column) + 0.5) * cellWidth
                    let edge = geometry.point(at: CGPoint(x: x, y: y))
                    let steps = Int(edge.distance / step)
                    guard steps < reachSteps else { continue }
                    position[row * columns + column] = UInt16(min(Int(edge.position * CGFloat(cells)), cells - 1))
                    distance[row * columns + column] = UInt16(min(steps, distanceSteps - 1))
                }
            }
            // Premultiplied RGBA in the display's color space: the format Core Animation can show
            // without converting.
            guard let context = CGContext(
                data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: shape.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return Strip(frame: frame, columns: columns, rows: rows, position: position, distance: distance, context: context)
        }
    }
}
