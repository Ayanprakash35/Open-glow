import AppKit
import Testing
@testable import OpenGlow

/// Renders the edge light to PNGs for eyeballing: full frames over a dark desktop, and a
/// time-vs-position strip (each row a frame, each column a point around the screen) that shows
/// flow as diagonal streaks and swells as bands. Only runs when OPENGLOW_PREVIEW_DIR is set:
/// `OPENGLOW_PREVIEW_DIR=/tmp/preview ./Scripts/test.sh --filter EdgeLightPreview`.
@Suite("Edge light preview")
@MainActor
struct EdgeLightPreviewTests {
    nonisolated private static let outputDirectory = ProcessInfo.processInfo.environment["OPENGLOW_PREVIEW_DIR"]
    private let size = CGSize(width: 1710, height: 1112)
    private let notch = NotchGeometry(leftEdgeX: 755, rightEdgeX: 955, bottomY: 1080)

    private func compose(_ rasterizer: EdgeLightRasterizer, _ images: [CGImage?], backdrop: CGFloat = 0.1) -> CGContext? {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: backdrop, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .medium
        // Same coordinates as the view: origin bottom-left.
        for (strip, image) in zip(rasterizer.strips, images) {
            if let image { context.draw(image, in: strip.frame) }
        }
        return context
    }

    private func write(_ image: CGImage?, _ name: String) throws {
        let directory = try #require(Self.outputDirectory)
        let rep = NSBitmapImageRep(cgImage: try #require(image))
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// A 92 BPM groove: big hits on 1 and 3, small ones between, a bass line under it.
    private func audio(at time: Double) -> AudioAnalysisState {
        var state = AudioAnalysisState()
        state.hasAudio = true
        state.isSilent = false
        let beat = 60.0 / 92
        let index = Int(time / beat)
        let since = time - Double(index) * beat
        let size: Float = index % 2 == 0 ? 1 : 0.22
        state.beatPulse = size * Float(exp(-since / 0.22))
        state.bass = 0.55 + 0.35 * Float(max(0, cos(2 * .pi * time / (beat * 4))))
        state.leftEnergy = 0.8
        state.rightEnergy = 0.8
        return state
    }

    @Test(.enabled(if: outputDirectory != nil))
    func renderPreviews() throws {
        try FileManager.default.createDirectory(atPath: try #require(Self.outputDirectory), withIntermediateDirectories: true)
        let rasterizer = EdgeLightRasterizer()
        let motion = GlowMotion(palette: GlowPalette(
            primary: PaletteColor(red: 0.95, green: 0.25, blue: 0.35),
            secondary: PaletteColor(red: 0.2, green: 0.9, blue: 0.45),
            balance: 0.55
        ))
        let shape = EdgeLightRasterizer.Shape(size: size, notch: notch, falloff: GlowDefaults.thickness, softness: Float(GlowDefaults.softness), maximumWidth: 1 + GlowMotionConfig.musicWidthGain)
        rasterizer.configure(shape, cells: motion.count)
        let geometry = EdgeGeometry(size: size, notch: notch)
        motion.perimeterPoints = Double(geometry.perimeter)

        let flow = GlowMotionSettings(animation: .flow)
        let music = GlowMotionSettings(animation: .musicSync)
        let fps = 30.0
        let brightness = Float(GlowDefaults.brightness)

        // The opening sweep, as soft starting colors.
        let intro = GlowMotion()
        intro.perimeterPoints = Double(geometry.perimeter)
        intro.introOrigin = Double(geometry.point(at: CGPoint(x: size.width / 2, y: 0)).position)
        intro.startIntro()
        var elapsed = 0.0
        for target in [0.35, 0.8, 1.3, 1.8] {
            while elapsed < target - 1e-9 {
                intro.step(dt: 1 / fps, audio: nil, settings: flow)
                elapsed += 1 / fps
            }
            _ = rasterizer.render(intro, brightness: brightness)
            let context = try #require(compose(rasterizer, rasterizer.snapshot()))
            try write(context.makeImage(), "intro-\(String(format: "%.2f", target)).png")
        }

        // Effects: an accent sweeping in and holding, a timer ring, the finish pulses' peak.
        let effects = GlowMotion(palette: PalettePresets.preset(withID: "ember").palette)
        effects.perimeterPoints = Double(geometry.perimeter)
        effects.introOrigin = intro.introOrigin
        effects.ringOrigin = Double(geometry.point(at: CGPoint(x: size.width / 2, y: size.height)).position)
        effects.playAccent(GlowPalette(
            primary: PaletteColor(red: 0.85, green: 0.47, blue: 0.34), secondary: PaletteColor(red: 0.98, green: 0.8, blue: 0.6), balance: 0.5
        ))
        effects.setTimerRing(1)
        var effectsTime = 0.0
        let shots: [(Double, String, () -> Void)] = [
            (0.6, "accent-sweep", {}), (3, "accent-hold", { effects.setTimerRing(0.6) }),
            (12, "ring-0.60", { effects.playTimerFinished() }), (12.4, "finish-peak", {}),
        ]
        for (at, name, then) in shots {
            while effectsTime < at - 1e-9 {
                effects.step(dt: 1 / fps, audio: nil, settings: flow)
                effectsTime += 1 / fps
            }
            _ = rasterizer.render(effects, brightness: brightness)
            try write(try #require(compose(rasterizer, rasterizer.snapshot())).makeImage(), "\(name).png")
            then()
        }

        // Time-vs-position strip: 12 s of idle flow, then 12 s of music.
        let columns = 600
        let rows = Int(24 * fps)
        var strip = [UInt8](repeating: 0, count: columns * rows * 3)
        let inset: CGFloat = 4
        let iw = size.width - 2 * inset, ih = size.height - 2 * inset
        let perimeter = 2 * (iw + ih)
        var renderTimes: [Double] = []
        for row in 0..<rows {
            let time = Double(row) / fps
            let isMusic = time >= 12
            motion.step(dt: row == 0 ? 0 : 1 / fps, audio: isMusic ? audio(at: time - 12) : nil, settings: isMusic ? music : flow)
            let started = Date()
            _ = rasterizer.render(motion, brightness: brightness)
            renderTimes.append(Date().timeIntervalSince(started))
            let context = try #require(compose(rasterizer, rasterizer.snapshot()))
            if [0, 6, 18, 18 + 0.33, 18 + 0.66].contains(where: { abs($0 - time) < 0.5 / fps }) {
                try write(context.makeImage(), "frame-\(isMusic ? "music" : "flow")-\(String(format: "%05.2f", time)).png")
            }
            let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
            for column in 0..<columns {
                // Clockwise from the top-left, `inset` points in.
                var s = CGFloat(column) / CGFloat(columns) * perimeter
                var x: CGFloat, y: CGFloat
                if s < iw { x = inset + s; y = size.height - inset }
                else if (s - iw) < ih { s -= iw; x = size.width - inset; y = size.height - inset - s }
                else if (s - iw - ih) < iw { s -= iw + ih; x = size.width - inset - s; y = inset }
                else { s -= 2 * iw + ih; x = inset; y = inset + s }
                // Bitmap rows run top to bottom.
                let offset = (Int(size.height) - 1 - Int(y)) * context.bytesPerRow + Int(x) * 4
                for c in 0..<3 { strip[(row * columns + column) * 3 + c] = data[offset + c] }
            }
        }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: columns, pixelsHigh: rows, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: columns * 3, bitsPerPixel: 24))
        strip.withUnsafeBufferPointer { rep.bitmapData?.update(from: $0.baseAddress!, count: strip.count) }
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: try #require(Self.outputDirectory)).appendingPathComponent("kymograph.png"))
        let sorted = renderTimes.sorted()
        print("render per frame (this build): median \(String(format: "%.2f", sorted[sorted.count / 2] * 1000)) ms, p95 \(String(format: "%.2f", sorted[sorted.count * 95 / 100] * 1000)) ms; cells \(rasterizer.strips.reduce(0) { $0 + $1.columns * $1.rows })")
    }
}
