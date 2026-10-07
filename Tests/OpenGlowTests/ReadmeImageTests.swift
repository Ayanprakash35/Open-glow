import AppKit
import Testing
@testable import OpenGlow

/// Renders the README's images from the real renderer. Only runs when OPENGLOW_README_IMAGES is
/// set: `OPENGLOW_README_IMAGES=docs/images ./Scripts/test.sh --filter ReadmeImageTests`.
@Suite("README images")
@MainActor
struct ReadmeImageTests {
    nonisolated private static let outputDirectory = ProcessInfo.processInfo.environment["OPENGLOW_README_IMAGES"]
    private let size = CGSize(width: 1710, height: 1112)
    private let notch = NotchGeometry(leftEdgeX: 755, rightEdgeX: 955, bottomY: 1080)

    private func palette(_ primary: (Double, Double, Double), _ secondary: (Double, Double, Double), balance: Double = 0.55) -> GlowPalette {
        GlowPalette(
            primary: PaletteColor(red: primary.0, green: primary.1, blue: primary.2),
            secondary: PaletteColor(red: secondary.0, green: secondary.1, blue: secondary.2),
            balance: balance
        )
    }

    /// A dark desktop-like backdrop: a soft vertical gradient.
    private func backdrop(_ context: CGContext, in rect: CGRect) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1), CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
    }

    /// Steps a motion through `seconds` of the given audio and returns the composed frame.
    private func frame(
        palette: GlowPalette, settings: GlowMotionSettings, seconds: Double, intro: Bool = false,
        thickness: CGFloat = 14, brightness: Float = 1,
        audio: ((Double) -> AudioAnalysisState?)? = nil
    ) throws -> CGImage {
        let rasterizer = EdgeLightRasterizer()
        let motion = GlowMotion(palette: palette)
        let geometry = EdgeGeometry(size: size, notch: notch)
        motion.perimeterPoints = Double(geometry.perimeter)
        motion.introOrigin = Double(geometry.point(at: CGPoint(x: size.width / 2, y: 0)).position)
        rasterizer.configure(.init(
            size: size, notch: notch, falloff: thickness, softness: Float(GlowDefaults.softness),
            maximumWidth: 1 + GlowMotionConfig.musicWidthGain
        ), cells: motion.count)
        if intro { motion.startIntro() }
        let dt = 1.0 / 60
        var time = 0.0
        while time < seconds {
            motion.step(dt: dt, audio: audio?(time), settings: settings)
            time += dt
        }
        let images = rasterizer.render(motion, brightness: brightness)
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        backdrop(context, in: CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        for (strip, image) in zip(rasterizer.strips, images) {
            if let image { context.draw(image, in: strip.frame) }
        }
        // The notch is black hardware on a real screen.
        let notchRect = CGRect(x: notch.leftEdgeX, y: notch.bottomY, width: notch.rightEdgeX - notch.leftEdgeX, height: size.height - notch.bottomY + 12)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: notchRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, _ name: String) throws {
        let directory = try #require(Self.outputDirectory)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// A steady groove with a big hit every other beat.
    private func groove(_ time: Double) -> AudioAnalysisState {
        var state = AudioAnalysisState()
        state.hasAudio = true
        state.isSilent = false
        let beat = 60.0 / 96
        let index = Int(time / beat)
        state.beatPulse = (index % 2 == 0 ? 1 : 0.25) * Float(exp(-(time - Double(index) * beat) / 0.22))
        state.bass = 0.75
        state.leftEnergy = 0.8
        state.rightEnergy = 0.8
        return state
    }

    @Test(.enabled(if: outputDirectory != nil))
    func renderReadmeImages() throws {
        try FileManager.default.createDirectory(atPath: try #require(Self.outputDirectory), withIntermediateDirectories: true)
        let sunset = palette((1.00, 0.55, 0.30), (0.92, 0.30, 0.62))
        let lagoon = PalettePresets.preset(withID: "lagoon").palette
        let aurora = PalettePresets.preset(withID: "aurora").palette

        // Hero: music playing, just after a big hit has swelled.
        let beat = 60.0 / 96
        try write(frame(palette: sunset, settings: GlowMotionSettings(animation: .musicSync), seconds: 4 * beat + 0.42, thickness: 16, audio: groove), "hero.png")
        // The idle flow.
        try write(frame(palette: lagoon, settings: GlowMotionSettings(animation: .flow), seconds: 6), "flow.png")
        // The opening sweep, as the fronts climb the sides.
        try write(frame(palette: .fallback, settings: GlowMotionSettings(animation: .flow), seconds: 0.85, intro: true), "opening-sweep.png")

        // Three palettes side by side, scaled down.
        let palettes = [GlowPalette.fallback, sunset, aurora]
        let thumb = CGSize(width: size.width / 3, height: size.height / 3)
        let gap: CGFloat = 24
        let strip = try #require(CGContext(
            data: nil, width: Int(thumb.width * 3 + gap * 2), height: Int(thumb.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        strip.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1))
        strip.fill(CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
        strip.interpolationQuality = .high
        for (index, palette) in palettes.enumerated() {
            let image = try frame(palette: palette, settings: GlowMotionSettings(animation: .flow), seconds: 3, thickness: 24)
            strip.draw(image, in: CGRect(x: CGFloat(index) * (thumb.width + gap), y: 0, width: thumb.width, height: thumb.height))
        }
        try write(try #require(strip.makeImage()), "palettes.png")
    }
}
