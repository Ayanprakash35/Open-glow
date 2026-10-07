import AppKit
import Testing
@testable import OpenGlow

// AppKit also brings in QuickDraw's `PaletteColor`; this one means the app's.

/// Renders a `width`×`height` image in `space` (sRGB by default); `draw` paints it.
private func makeImage(
    width: Int,
    height: Int,
    space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB),
    alphaInfo: CGImageAlphaInfo = .premultipliedLast,
    draw: (CGContext) -> Void
) throws -> CGImage {
    let space = try #require(space)
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: alphaInfo.rawValue
    ))
    draw(context)
    return try #require(context.makeImage())
}

/// An sRGB image of solid rectangles painted in order over `background` (transparent if nil).
private func makeImage(
    width: Int, height: Int, background: PaletteColor?, _ fills: [(CGRect, PaletteColor)] = []
) throws -> CGImage {
    try makeImage(width: width, height: height) { context in
        if let background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        for (rect, color) in fills {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
    }
}

private func pngData(_ image: CGImage) throws -> Data {
    try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

private func hueDegrees(_ color: PaletteColor) -> Double {
    ColorExtractor.HSB(color).hue * 360
}

/// Shortest way around the hue circle between two hues, in degrees.
private func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
    let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
    return min(difference, 360 - difference)
}

/// Both palette colors should be glow-ready whatever the source.
private func expectGlowReady(_ palette: GlowPalette, sourceLocation: SourceLocation = #_sourceLocation) {
    for color in [palette.primary, palette.secondary] {
        let hsb = ColorExtractor.HSB(color)
        #expect(hsb.brightness >= ColorExtractorConfig.minBrightness - 1e-9, "\(color) too dark", sourceLocation: sourceLocation)
        #expect(hsb.saturation >= ColorExtractorConfig.minSaturation - 1e-9, "\(color) too washed out", sourceLocation: sourceLocation)
    }
}

private let red = PaletteColor(red: 0.9, green: 0.1, blue: 0.1)
private let blue = PaletteColor(red: 0.1, green: 0.2, blue: 0.9)

@Suite("Color extractor")
struct ColorExtractorTests {
    @Test func labConversionMatchesReferenceValues() {
        let lab = ColorExtractor.Lab(PaletteColor(red: 1, green: 0, blue: 0))
        #expect(abs(lab.l - 53.24) < 0.05 && abs(lab.a - 80.09) < 0.05 && abs(lab.b - 67.20) < 0.05, "\(lab)")
        let white = ColorExtractor.Lab(PaletteColor(red: 1, green: 1, blue: 1))
        #expect(abs(white.l - 100) < 0.01 && white.chroma < 0.01, "\(white)")
        #expect(ColorExtractor.Lab(PaletteColor(red: 0, green: 0, blue: 0)).distance(to: .zero) < 1e-9)

        for color in [PaletteColor(red: 0.2, green: 0.6, blue: 0.9), PaletteColor(red: 0.02, green: 0.01, blue: 0.03), red, blue] {
            let back = ColorExtractor.Lab(color).rgb
            #expect(abs(back.red - color.red) < 1e-6 && abs(back.green - color.green) < 1e-6 && abs(back.blue - color.blue) < 1e-6, "\(color) → \(back)")
        }
    }

    @Test func twoColorsSplitTheRingByShare() throws {
        let image = try makeImage(width: 100, height: 100, background: blue, [(CGRect(x: 0, y: 0, width: 70, height: 100), red)])
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .artwork)
        #expect(hueDistance(hueDegrees(result.palette.primary), 0) < 15, "primary \(result.palette.primary)")
        #expect(hueDistance(hueDegrees(result.palette.secondary), 230) < 20, "secondary \(result.palette.secondary)")
        #expect(abs(result.palette.balance - 0.7) < 0.05, "balance \(result.palette.balance)")
        expectGlowReady(result.palette)
    }

    @Test func blackBackgroundIsIgnored() throws {
        let orange = PaletteColor(red: 1, green: 0.55, blue: 0)
        let image = try makeImage(
            width: 200, height: 200, background: PaletteColor(red: 0.02, green: 0.02, blue: 0.03),
            [(CGRect(x: 60, y: 60, width: 70, height: 70), orange)]
        )
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .artwork)
        #expect(hueDistance(hueDegrees(result.palette.primary), hueDegrees(orange)) < 10, "primary \(result.palette.primary)")
        // No second color in the art, so the secondary is a variation on orange, not black.
        #expect(result.palette.secondary != result.palette.primary)
        expectGlowReady(result.palette)
    }

    @Test func whiteBackgroundIsIgnored() throws {
        let green = PaletteColor(red: 0.1, green: 0.65, blue: 0.2)
        let image = try makeImage(width: 300, height: 300) { context in
            context.setFillColor(PaletteColor(red: 1, green: 1, blue: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            context.setFillColor(green.cgColor)
            context.fillEllipse(in: CGRect(x: 90, y: 90, width: 120, height: 120))
        }
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .artwork)
        #expect(hueDistance(hueDegrees(result.palette.primary), hueDegrees(green)) < 10, "primary \(result.palette.primary)")
    }

    @Test func grayscaleArtworkGlowsWhite() throws {
        let gray = CGColorSpace(name: CGColorSpace.linearGray)
        let image = try makeImage(width: 256, height: 64, space: gray, alphaInfo: .none) { context in
            let colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray
            guard let gradient = CGGradient(colorsSpace: gray, colors: colors, locations: nil) else { return }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 256, y: 0), options: [])
        }
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .monochrome)
        let white = ColorExtractor.HSB(result.palette.primary)
        let silver = ColorExtractor.HSB(result.palette.secondary)
        #expect(white.brightness > 0.93 && white.saturation < 0.06, "primary \(result.palette.primary) should be white")
        #expect(silver.brightness < white.brightness && silver.saturation < 0.12, "secondary \(result.palette.secondary) should be silver")
    }

    @Test func blackAndWhitePhotoGlowsWhiteNotDefault() throws {
        // Like an eclipse-and-tree cover: gray sky, a black disc, a dark ground band.
        let sky = PaletteColor(red: 0.66, green: 0.66, blue: 0.66)
        let image = try makeImage(width: 200, height: 200, background: sky, [
            (CGRect(x: 80, y: 120, width: 50, height: 50), PaletteColor(red: 0.05, green: 0.05, blue: 0.05)),
            (CGRect(x: 0, y: 0, width: 200, height: 40), PaletteColor(red: 0.12, green: 0.12, blue: 0.12)),
        ])
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .monochrome)
        #expect(result.palette != GlowPalette.fallback)
    }

    @Test func sepiaArtworkGlowsWarmWhite() throws {
        let sepia = PaletteColor(red: 0.62, green: 0.56, blue: 0.48)
        let image = try makeImage(width: 100, height: 100, background: sepia, [
            (CGRect(x: 0, y: 0, width: 100, height: 40), PaletteColor(red: 0.30, green: 0.27, blue: 0.23)),
        ])
        let result = ColorExtractor.extract(from: image)
        // Weakly warm: either boosted toward its hue or a warm white — never cold or the default.
        #expect(result.source == .boosted || result.source == .monochrome)
        let primary = ColorExtractor.HSB(result.palette.primary)
        #expect(hueDistance(primary.hue * 360, 35) < 25, "primary \(result.palette.primary) should stay warm")
    }

    @Test func pastelArtworkStaysSoft() throws {
        let pink = PaletteColor(red: 0.97, green: 0.80, blue: 0.86)
        let mint = PaletteColor(red: 0.78, green: 0.94, blue: 0.86)
        let image = try makeImage(width: 120, height: 120, background: pink, [
            (CGRect(x: 0, y: 0, width: 120, height: 45), mint),
        ])
        let result = ColorExtractor.extract(from: image)
        for color in [result.palette.primary, result.palette.secondary] {
            let hsb = ColorExtractor.HSB(color)
            #expect(hsb.saturation <= ColorExtractorConfig.minSaturation + 0.05, "\(color) pushed past pastel")
            #expect(hsb.brightness >= 0.9)
        }
    }

    @Test func mutedArtworkIsBoosted() throws {
        let brown = PaletteColor(red: 0.55, green: 0.47, blue: 0.40)
        let beige = PaletteColor(red: 0.80, green: 0.74, blue: 0.66)
        let image = try makeImage(width: 120, height: 120, background: beige, [
            (CGRect(x: 0, y: 0, width: 120, height: 30), brown),
            (CGRect(x: 0, y: 60, width: 120, height: 30), brown),
        ])
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .boosted)
        let primary = ColorExtractor.HSB(result.palette.primary)
        #expect(primary.saturation >= ColorExtractorConfig.minSaturation - 1e-9, "primary \(result.palette.primary)")
        #expect(primary.saturation > ColorExtractor.HSB(beige).saturation)
        #expect(hueDistance(primary.hue * 360, 30) < 20, "primary \(result.palette.primary) should stay warm")
        expectGlowReady(result.palette)
    }

    @Test func darkNavyGlowsBrightBlue() throws {
        let navy = PaletteColor(red: 0.06, green: 0.10, blue: 0.35)
        let image = try makeImage(width: 64, height: 64, background: navy, [
            (CGRect(x: 0, y: 0, width: 64, height: 20), PaletteColor(red: 0.04, green: 0.06, blue: 0.24)),
        ])
        let result = ColorExtractor.extract(from: image)
        let primary = ColorExtractor.HSB(result.palette.primary)
        #expect(result.source == .artwork)
        #expect(primary.brightness >= 0.8, "primary \(result.palette.primary)")
        #expect(hueDistance(primary.hue * 360, hueDegrees(navy)) < 10, "primary \(result.palette.primary)")
    }

    @Test func singleColorGetsAHueShiftedSecondary() throws {
        let teal = PaletteColor(red: 0.0, green: 0.55, blue: 0.55)
        let result = ColorExtractor.extract(from: try makeImage(width: 50, height: 50, background: teal))
        let palette = result.palette
        #expect(result.source == .artwork)
        #expect(palette.secondary != palette.primary)
        let shift = hueDistance(hueDegrees(palette.primary), hueDegrees(palette.secondary))
        #expect(abs(shift - ColorExtractorConfig.derivedHueShiftDegrees) < 1, "shift \(shift)°")
        #expect(palette.balance == ColorExtractorConfig.derivedBalance)
        expectGlowReady(palette)
    }

    @Test func sameInputSameResult() throws {
        let image = try makeImage(width: 400, height: 300) { context in
            let colors = [red.cgColor, PaletteColor(red: 0.9, green: 0.8, blue: 0.1).cgColor, blue.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 400, y: 300), options: [])
        }
        let first = ColorExtractor.extract(from: image)
        #expect(ColorExtractor.extract(from: image) == first)
        #expect(ColorExtractor.extract(fromImageData: try pngData(image)) == ColorExtractor.extract(fromImageData: try pngData(image)))
    }

    @Test func decodesPNGData() throws {
        let image = try makeImage(width: 80, height: 80, background: blue, [(CGRect(x: 0, y: 0, width: 50, height: 80), red)])
        let decoded = try #require(ColorExtractor.extract(fromImageData: try pngData(image)))
        let direct = ColorExtractor.extract(from: image)
        #expect(decoded.source == direct.source)
        for (lhs, rhs) in [(decoded.palette.primary, direct.palette.primary), (decoded.palette.secondary, direct.palette.secondary)] {
            #expect(abs(lhs.red - rhs.red) < 0.01 && abs(lhs.green - rhs.green) < 0.01 && abs(lhs.blue - rhs.blue) < 0.01, "\(lhs) vs \(rhs)")
        }
        #expect(abs(decoded.palette.balance - direct.palette.balance) < 0.01)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(ColorExtractor.extract(fromImageData: Data()) == nil)
        #expect(ColorExtractor.extract(fromImageData: Data("definitely not a JPEG".utf8)) == nil)
        #expect(ColorExtractor.extract(fromImageData: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37) })) == nil)
    }

    @Test func onePixelImage() throws {
        let green = PaletteColor(red: 0.2, green: 0.8, blue: 0.3)
        let result = ColorExtractor.extract(from: try makeImage(width: 1, height: 1, background: green))
        #expect(result.source == .artwork)
        #expect(hueDistance(hueDegrees(result.palette.primary), hueDegrees(green)) < 2)
    }

    @Test func transparentPixelsDoNotDiluteTheArtwork() throws {
        // A 1% dot of red on a transparent canvas: counted against the whole canvas it would be
        // below the noise threshold; counted against the opaque pixels it's everything.
        let image = try makeImage(width: 100, height: 100, background: nil, [(CGRect(x: 40, y: 40, width: 10, height: 10), red)])
        let result = ColorExtractor.extract(from: image)
        #expect(result.source == .artwork)
        #expect(hueDistance(hueDegrees(result.palette.primary), 0) < 10, "primary \(result.palette.primary)")

        let empty = ColorExtractor.extract(from: try makeImage(width: 32, height: 32, background: nil))
        #expect(empty == ColorExtractor.Result(palette: .fallback, source: .fallback))
    }

    @Test func convertsCMYKAndIndexedImages() throws {
        let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)
        let cyanImage = try makeImage(width: 40, height: 40, space: cmyk, alphaInfo: .none) { context in
            guard let cyan = CGColor(colorSpace: context.colorSpace ?? CGColorSpaceCreateDeviceCMYK(), components: [1, 0, 0, 0, 1]) else { return }
            context.setFillColor(cyan)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let cyanResult = ColorExtractor.extract(from: cyanImage)
        #expect(cyanResult.source == .artwork)
        #expect(hueDistance(hueDegrees(cyanResult.palette.primary), 195) < 20, "primary \(cyanResult.palette.primary)")

        // Two-entry palette, magenta and black; three quarters of the pixels are magenta.
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let table: [UInt8] = [255, 0, 255, 0, 0, 0]
        let indexedSpace = try #require(CGColorSpace(indexedBaseSpace: sRGB, last: 1, colorTable: table))
        let indices = Data((0..<(16 * 16)).map { $0 % 4 == 0 ? 1 : 0 })
        let provider = try #require(CGDataProvider(data: indices as CFData))
        let indexedImage = try #require(CGImage(
            width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 16, space: indexedSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let indexedResult = ColorExtractor.extract(from: indexedImage)
        #expect(indexedResult.source == .artwork)
        #expect(hueDistance(hueDegrees(indexedResult.palette.primary), 300) < 5, "primary \(indexedResult.palette.primary)")
    }

    @Test func concurrentCallsAgree() async throws {
        let data = try pngData(try makeImage(width: 300, height: 300, background: blue, [(CGRect(x: 0, y: 0, width: 120, height: 300), red)]))
        let expected = ColorExtractor.extract(fromImageData: data)
        #expect(expected != nil)
        let results = await withTaskGroup(of: ColorExtractor.Result?.self) { group in
            for _ in 0..<16 {
                group.addTask { ColorExtractor.extract(fromImageData: data) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 16)
        #expect(results.allSatisfy { $0 == expected })
    }

    @Test func largeImageIsFast() throws {
        let side = 1000
        let image = try makeImage(width: side, height: side) { context in
            let colors = [red, PaletteColor(red: 0.95, green: 0.75, blue: 0.1), PaletteColor(red: 0.1, green: 0.7, blue: 0.4), blue].map(\.cgColor) as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            context.setFillColor(PaletteColor(red: 0.05, green: 0.05, blue: 0.05).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: side / 3, height: side))
        }
        // Best of several runs: other suites run in parallel and can preempt any single one.
        let clock = ContinuousClock()
        let elapsed = (0..<5).map { _ in clock.measure { _ = ColorExtractor.extract(from: image) } }.min() ?? .zero
        // Budget is 50 ms in release; debug builds run the clustering loops several times slower.
        #expect(elapsed < .milliseconds(150), "took \(elapsed)")
    }
}
