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
    /// Pixel buffers per strip, shown in turn so a frame is never drawn into the one on screen.
    /// Two is enough unless the compositor still holds the older one. Sane range: 2–4.
    static let maximumBuffersPerStrip = 3
}

/// Turns `GlowMotion`'s per-cell colors, brightness and widths into pixels: light coming in from
/// the screen edge, brightest at the edge and falling off smoothly inward.
///
/// Only the border can ever be lit, so the light is computed in strips — zones along the top
/// (tall enough to wrap the notch), bottom, left and right: the corners, the notch, the spans of
/// edge between them, and the sides — at a cell size a few to a falloff length, and Core
/// Animation scales each strip up with linear filtering. Corners and the notch get
/// square cells; elsewhere a cell spans a whole perimeter cell along the edge. Every cell's distance from the edge
/// and position around the screen are worked out once per size or shape change (`EdgeGeometry`);
/// a frame is then, per cell, one table lookup and two integer multiplies.
///
/// Each strip's cells are kept sorted by distance from the edge, so a frame only visits the cells
/// the current widest glow can reach (the rest stay dark from before). Strips are drawn straight
/// into IOSurfaces that layers show as they are: no image copy per frame, and nothing for Core
/// Animation to copy at commit. A frame identical to the last one isn't drawn at all.
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
        /// The strip's lit cells, nearest the edge first: where each sits in the pixel buffer
        /// (in pixels from its start), …
        let pixel: [Int32]
        /// … which motion cell lights it, …
        let position: [UInt16]
        /// … and its distance from the edge in `distanceStep`s.
        let distance: [UInt16]
        /// `within[d]`: how many of the lit cells are fewer than `d` distance steps from the edge.
        let within: [Int32]
        let bytesPerRow: Int
    }

    /// A strip's pixel buffers, and which one is on screen.
    private struct Buffers {
        var surfaces: [IOSurface] = []
        /// Per surface: how many leading lit cells it was last drawn with; beyond them it's dark.
        var drawnCells: [Int] = []
        /// Per surface: the frame it was last drawn for.
        var drawnFrame: [Int] = []
        var shown: Int?
    }

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
        /// The display's own color space. Strips tagged with it are shown as they are; in any
        /// other space the compositor color-matches them.
        var colorSpace: CGColorSpace = Shape.sRGB
    }

    /// 32-bit BGRA, premultiplied — the layout Core Animation shows without converting.
    private static let pixelFormat: UInt32 = 0x4247_5241 // 'BGRA'

    private(set) var strips: [Strip] = []
    private(set) var shape: Shape?
    private var buffers: [Buffers] = []
    /// Falloff per width bucket and distance step, in 8.8 fixed point (0...256).
    private var fixedTable: [UInt16] = []
    private var distanceSteps = 1
    /// Per width bucket: the distance step from which its falloff is zero.
    private var darkFrom: [Int] = []
    private var bucketOfCell: [Int32] = []
    private var packedColor: [UInt32] = []
    private var drawnBucket: [Int32] = []
    private var drawnColor: [UInt32] = []
    private var hasDrawn = false
    private var frameNumber = 0
    /// Cells visited by the last drawn frame, across all strips — for measurements.
    private(set) var lastCellCount = 0

    /// Rebuilds the cell tables for `shape` if it changed. Returns whether it did.
    @discardableResult
    func configure(_ shape: Shape, cells: Int) -> Bool {
        guard shape != self.shape, shape.size.width > 0, shape.size.height > 0 else { return false }
        self.shape = shape
        buildTable(shape)
        buildStrips(shape, cells: cells)
        bucketOfCell = Array(repeating: 0, count: cells)
        packedColor = Array(repeating: 0, count: cells)
        hasDrawn = false
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

    /// Draws the current motion state. Returns the surface to show for each strip, or nil when the
    /// light is exactly as last drawn, so there's nothing to present (or no pixel buffer could be
    /// made).
    func render(_ motion: GlowMotion, brightness: Float) -> [IOSurface]? {
        guard shape != nil else { return nil }
        let widest = pack(motion, brightness: brightness)
        if hasDrawn, bucketOfCell == drawnBucket, packedColor == drawnColor { return nil }
        let targets = buffers.indices.compactMap(nextBuffer)
        guard targets.count == buffers.count else { return nil }
        frameNumber += 1
        let reachSteps = darkFrom[Int(widest)]
        lastCellCount = 0
        var shown: [IOSurface] = []
        for (index, target) in targets.enumerated() {
            let strip = strips[index]
            let count = Int(strip.within[min(reachSteps, strip.within.count - 1)])
            let surface = buffers[index].surfaces[target]
            draw(strip, into: surface, cells: count, clearingTo: buffers[index].drawnCells[target])
            buffers[index].drawnCells[target] = count
            buffers[index].drawnFrame[target] = frameNumber
            buffers[index].shown = target
            lastCellCount += count
            shown.append(surface)
        }
        drawnBucket = bucketOfCell
        drawnColor = packedColor
        hasDrawn = true
        return shown
    }

    /// The strips as last drawn, as images — for tests and previews.
    func snapshot() -> [CGImage?] {
        zip(strips, buffers).map { strip, buffers in
            guard let shown = buffers.shown else { return nil }
            let surface = buffers.surfaces[shown]
            surface.lock(options: .readOnly, seed: nil)
            defer { surface.unlock(options: .readOnly, seed: nil) }
            let data = Data(bytes: surface.baseAddress, count: strip.bytesPerRow * strip.rows)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(
                width: strip.columns, height: strip.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: strip.bytesPerRow, space: shape?.colorSpace ?? Shape.sRGB,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }

    // MARK: - Frames

    /// Per perimeter cell: its full-strength premultiplied color, packed as the bytes B, G, R, A in
    /// memory, and where its width's falloff row starts in the table. Returns the widest bucket.
    private func pack(_ motion: GlowMotion, brightness: Float) -> Int32 {
        guard let shape else { return 0 }
        let buckets = EdgeLightConfig.widthBuckets
        let span = max(shape.maximumWidth - 1, 0.0001)
        let steps = Int32(distanceSteps)
        var widest: Int32 = 0
        motion.width.withUnsafeBufferPointer { width in
        motion.amplitude.withUnsafeBufferPointer { amplitude in
        motion.red.withUnsafeBufferPointer { red in
        motion.green.withUnsafeBufferPointer { green in
        motion.blue.withUnsafeBufferPointer { blue in
        packedColor.withUnsafeMutableBufferPointer { packed in
        bucketOfCell.withUnsafeMutableBufferPointer { bucket in
            for i in 0..<min(width.count, bucket.count) {
                let b = Int32((Self.unit((width[i] - 1) / span) * Float(buckets - 1)).rounded())
                bucket[i] = b * steps
                let alpha = Self.unit(amplitude[i] * brightness)
                let r = UInt32(Self.unit(red[i]) * alpha * 255 + 0.5)
                let g = UInt32(Self.unit(green[i]) * alpha * 255 + 0.5)
                let b8 = UInt32(Self.unit(blue[i]) * alpha * 255 + 0.5)
                let a = UInt32(alpha * 255 + 0.5)
                packed[i] = b8 | g << 8 | r << 16 | a << 24
                // A dark cell lights nothing, however wide.
                if a > 0 { widest = max(widest, b) }
            }
        }}}}}}}
        return widest
    }

    /// `value` clamped to 0...1, with NaN as 0: converting a NaN to an integer traps, and plain
    /// `min`/`max` pass a NaN through.
    @inline(__always)
    private static func unit(_ value: Float) -> Float {
        value > 0 ? min(value, 1) : 0
    }

    /// One strip: per lit cell within reach, the perimeter cell's packed color scaled by the
    /// falloff at the cell's distance — two integer multiplies scale all four channels at once.
    /// Cells the previous use of this buffer lit but this frame doesn't reach are cleared.
    private func draw(_ strip: Strip, into surface: IOSurface, cells count: Int, clearingTo drawn: Int) {
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let pixels = surface.baseAddress.bindMemory(to: UInt32.self, capacity: strip.bytesPerRow / 4 * strip.rows)
        packedColor.withUnsafeBufferPointer { color in
        bucketOfCell.withUnsafeBufferPointer { bucket in
        fixedTable.withUnsafeBufferPointer { table in
        strip.pixel.withUnsafeBufferPointer { pixel in
        strip.position.withUnsafeBufferPointer { position in
        strip.distance.withUnsafeBufferPointer { distance in
            for cell in 0..<count {
                let index = Int(position[cell])
                // Falloff in 0...256 (8.8 fixed point).
                let scale = UInt32(table[Int(bucket[index]) + Int(distance[cell])])
                let packed = color[index]
                let blueRed = ((packed & 0x00FF_00FF) &* scale) >> 8 & 0x00FF_00FF
                let greenAlpha = ((packed >> 8) & 0x00FF_00FF) &* scale & 0xFF00_FF00
                pixels[Int(pixel[cell])] = blueRed | greenAlpha
            }
            for cell in count..<max(drawn, count) { pixels[Int(pixel[cell])] = 0 }
        }}}}}}
    }

    /// The buffer of a strip to draw the next frame into: one that isn't on screen and that the
    /// compositor has let go of, a new one while the strip may have more, or failing both the one
    /// shown longest ago (a frame never stalls for the compositor). Nil only if none can be made.
    private func nextBuffer(strip index: Int) -> Int? {
        let current = buffers[index]
        let candidates = current.surfaces.indices.filter { $0 != current.shown }
        if let free = candidates.first(where: { !current.surfaces[$0].isInUse }) { return free }
        if current.surfaces.count < EdgeLightConfig.maximumBuffersPerStrip,
           let shape, let surface = Self.makeSurface(for: strips[index], colorSpace: shape.colorSpace) {
            buffers[index].surfaces.append(surface)
            buffers[index].drawnCells.append(0)
            buffers[index].drawnFrame.append(0)
            return current.surfaces.count
        }
        return candidates.min { current.drawnFrame[$0] < current.drawnFrame[$1] } ?? current.shown
    }

    private static func makeSurface(for strip: Strip, colorSpace: CGColorSpace) -> IOSurface? {
        guard let surface = IOSurface(properties: [
            .width: strip.columns, .height: strip.rows, .bytesPerElement: 4,
            .bytesPerRow: strip.bytesPerRow, .pixelFormat: pixelFormat,
        ]), surface.bytesPerRow == strip.bytesPerRow else { return nil }
        if let colorSpace = colorSpace.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpace)
        }
        surface.lock(options: [], seed: nil)
        memset(surface.baseAddress, 0, strip.bytesPerRow * strip.rows)
        surface.unlock(options: [], seed: nil)
        return surface
    }

    // MARK: - Setup

    /// Falloff for every width bucket and distance step, tapered to zero at the reach.
    private func buildTable(_ shape: Shape) {
        let reach = Float(Self.reach(falloff: shape.falloff, softness: shape.softness, maximumWidth: shape.maximumWidth))
        let step = EdgeLightConfig.distanceStep
        distanceSteps = max(Int((reach / step).rounded(.up)) + 1, 2)
        let buckets = EdgeLightConfig.widthBuckets
        var table = [Float](repeating: 0, count: buckets * distanceSteps)
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
        // A falloff of 1/256 or less scales even a full-strength channel (255) to zero.
        darkFrom = (0..<buckets).map { b in
            let row = fixedTable[(b * distanceSteps)..<((b + 1) * distanceSteps)]
            return (row.lastIndex { $0 > 1 } ?? -1) - b * distanceSteps + 1
        }
    }

    /// Splits the border into zones and builds each one's cells. Corners and the notch need
    /// square cells, since light reaches them from two directions. Between them only one side
    /// lights a cell, and along that side the light changes only from one perimeter cell to the
    /// next, so those zones get one cell per perimeter cell along the edge (Core Animation's
    /// filtering blends neighbors) — a fraction of the cells for the same picture.
    private func buildStrips(_ shape: Shape, cells: Int) {
        let geometry = EdgeGeometry(size: shape.size, notch: shape.notch)
        let reach = Self.reach(falloff: shape.falloff, softness: shape.softness, maximumWidth: shape.maximumWidth)
        let cellSize = max(shape.falloff / EdgeLightConfig.cellsPerFalloff, EdgeLightConfig.minimumCellSize)
        let along = max(geometry.perimeter / CGFloat(cells), cellSize)
        let w = shape.size.width, h = shape.size.height
        // Zone edges on whole points, as in `spans`: a screen pixel split between two zones gets
        // both layers' partial coverage blended, which draws a faint dark line along the seam.
        let depth = reach.rounded(.up)
        let topHeight = min((depth + geometry.notchDepth).rounded(.up), h / 2)
        let bottomHeight = min(depth, h / 2)
        let sideWidth = min(depth, w / 2)
        let sideHeight = max(h - topHeight - bottomHeight, 0)

        var notchSpan: ClosedRange<CGFloat>?
        if let notch = shape.notch, geometry.notchDepth > 0 {
            notchSpan = (notch.leftEdgeX - reach)...(notch.rightEdgeX + reach)
        }
        var zones: [(frame: CGRect, columns: Int, rows: Int)] = []
        for (y, height, notch) in [(h - topHeight, topHeight, notchSpan), (0, bottomHeight, nil)] {
            guard height >= 1 else { continue }
            let rows = max(Int((height / cellSize).rounded(.up)), 1)
            for (span, square) in Self.spans(width: w, reach: reach, notch: notch, minimumGap: 2 * along) {
                let width = span.upperBound - span.lowerBound
                let columns = square ? Int((width / cellSize).rounded(.up)) : Int((width / along).rounded())
                zones.append((CGRect(x: span.lowerBound, y: y, width: width, height: height), max(columns, 1), rows))
            }
        }
        if sideHeight >= 1, sideWidth >= 1 {
            let columns = max(Int((sideWidth / cellSize).rounded(.up)), 1)
            let rows = max(Int((sideHeight / along).rounded()), 1)
            zones.append((CGRect(x: 0, y: bottomHeight, width: sideWidth, height: sideHeight), columns, rows))
            zones.append((CGRect(x: w - sideWidth, y: bottomHeight, width: sideWidth, height: sideHeight), columns, rows))
        }
        let reachSteps = Int(reach / CGFloat(EdgeLightConfig.distanceStep))
        strips = zones.map { makeStrip(frame: $0.frame, columns: $0.columns, rows: $0.rows, geometry: geometry, cells: cells, reachSteps: reachSteps) }
        buffers = Array(repeating: Buffers(), count: strips.count)
    }

    /// A top or bottom strip's zones, left to right: square-celled around the corners and the
    /// notch, edge-celled between. Gaps narrower than `minimumGap` join their neighbors.
    static func spans(width: CGFloat, reach: CGFloat, notch: ClosedRange<CGFloat>?, minimumGap: CGFloat) -> [(ClosedRange<CGFloat>, square: Bool)] {
        // Seams on whole points, so no screen pixel is split between two zones.
        let reach = reach.rounded(.up)
        var squares: [ClosedRange<CGFloat>] = [0...min(reach, width), max(width - reach, 0)...width]
        if let notch {
            squares.append(max(notch.lowerBound.rounded(.down), 0)...min(notch.upperBound.rounded(.up), width))
        }
        squares.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        for span in squares {
            if let last = merged.last, span.lowerBound - last.upperBound < minimumGap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        var result: [(ClosedRange<CGFloat>, square: Bool)] = []
        for (index, span) in merged.enumerated() {
            if index > 0 { result.append((merged[index - 1].upperBound...span.lowerBound, false)) }
            result.append((span, true))
        }
        return result
    }

    private func makeStrip(frame: CGRect, columns: Int, rows: Int, geometry: EdgeGeometry, cells: Int, reachSteps: Int) -> Strip {
        let step = CGFloat(EdgeLightConfig.distanceStep)
        let cellWidth = frame.width / CGFloat(columns)
        let cellHeight = frame.height / CGFloat(rows)
        // Rows padded the way IOSurface prefers for the compositor.
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, columns * 4)
        var lit: [(pixel: Int32, position: UInt16, distance: UInt16)] = []
        lit.reserveCapacity(columns * rows)
        for row in 0..<rows {
            // Pixel rows run top to bottom; the view's Y runs upward.
            let y = frame.maxY - (CGFloat(row) + 0.5) * cellHeight
            for column in 0..<columns {
                let x = frame.minX + (CGFloat(column) + 0.5) * cellWidth
                let edge = geometry.point(at: CGPoint(x: x, y: y))
                let steps = Int(edge.distance / step)
                guard steps < reachSteps else { continue }
                lit.append((
                    Int32(row * bytesPerRow / 4 + column),
                    UInt16(min(Int(edge.position * CGFloat(cells)), cells - 1)),
                    UInt16(min(steps, distanceSteps - 1))
                ))
            }
        }
        // Nearest the edge first; within a distance, in memory order.
        lit.sort { ($0.distance, $0.pixel) < ($1.distance, $1.pixel) }
        var within = [Int32](repeating: Int32(lit.count), count: distanceSteps + 1)
        var next = 0
        for d in 0...distanceSteps {
            while next < lit.count, Int(lit[next].distance) < d { next += 1 }
            within[d] = Int32(next)
        }
        return Strip(
            frame: frame, columns: columns, rows: rows,
            pixel: lit.map(\.pixel), position: lit.map(\.position), distance: lit.map(\.distance),
            within: within, bytesPerRow: bytesPerRow
        )
    }
}
