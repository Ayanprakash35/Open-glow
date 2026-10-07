import AppKit

/// Album-art color extraction tuning. Lab values are CIELAB (D65 white): L* runs 0 (black) to 100
/// (white); chroma is the distance from the gray axis, 0 for neutrals and up to ~130 for the most
/// vivid sRGB blue; ΔE is the straight-line distance between two Lab colors, where ~2 is barely
/// noticeable and 20 or more reads as a different color.
enum ColorExtractorConfig {
    /// Longest side, in pixels, the artwork is shrunk to before analysis (at most 64×64 = 4,096
    /// samples). Plenty for color statistics, and it caps the cost of everything after the decode.
    /// Sane range: 32–128.
    static let sampleSide = 64
    /// Pixels less opaque than this (0–1) are skipped: 8-bit premultiplied color keeps too few
    /// levels to recover their hue. The rest count in proportion to their opacity, so a
    /// transparent margin neither counts as black nor dilutes the artwork's real colors, while
    /// artwork that is translucent all over still shows its colors. Sane range: 0.02–0.25.
    static let minAlpha = 0.1

    /// Cell size, in Lab units, of the fine histogram samples are pooled into before clustering,
    /// so k-means runs over a few hundred weighted colors instead of thousands of pixels. Each
    /// cell's color is its members' exact mean; the size only limits how finely samples can be
    /// split between clusters. Sane range: 1–5.
    static let poolCellSize = 3.0
    /// Number of k-means clusters: enough to separate a cover's background, subject and an accent
    /// without splitting one color into many shades. Sane range: 3–8.
    static let clusterCount = 5
    /// Most k-means refinement passes; runs stop early once no color changes cluster.
    /// Sane range: 5–20.
    static let maxIterations = 12
    /// Cell size, in Lab units, of the histogram whose most populated cells seed k-means.
    /// Sane range: 6–16.
    static let seedCellSize = 10.0
    /// Minimum ΔE between two seeds, so each cluster starts on a genuinely different color.
    /// Sane range: 8–20.
    static let seedSeparation = 12.0

    /// Colors covering less than this fraction of the artwork (weighted by opacity) are ignored
    /// as noise. Judged after look-alike clusters merge, since the soft edges of a small accent
    /// spread over several clusters of one hue. Sane range: 0.005–0.03.
    static let minColorShare = 0.01
    /// Chroma below which a cluster is neutral (gray, black, white) with no dependable hue.
    /// Sane range: 4–12.
    static let neutralChroma = 8.0
    /// Chroma from which a cluster counts as vivid. Clusters between `neutralChroma` and this are
    /// weakly colored: they lead the palette only when nothing vivid exists. Sane range: 15–30.
    static let vividChroma = 20.0
    /// L* below which a cluster that isn't vivid counts as near-black: in shadows, a little chroma
    /// is usually compression noise rather than a color. A deep navy is vivid and still passes.
    /// Sane range: 5–20.
    static let nearBlackLightness = 12.0
    /// L* above which a cluster that isn't vivid counts as near-white, so cream or paper-tinted
    /// backgrounds don't glow orange. Sane range: 85–97.
    static let nearWhiteLightness = 94.0
    /// Chroma at which a cluster's vividness weight tops out when clusters are ranked by
    /// share × vividness. Lower lets large muted areas outrank small vivid ones. Sane range: 30–80.
    static let fullWeightChroma = 50.0

    /// Minimum ΔE between two glow-ready colors for them to count as different colors. Closer
    /// clusters, such as the lit and shadowed sides of one red, merge into one. Sane range: 15–25.
    static let distinctDeltaE = 20.0
    /// Hue rotation, in degrees, of the secondary derived from the primary when the artwork offers
    /// no second color. Sane range: 25–40.
    static let derivedHueShiftDegrees = 30.0
    /// Balance (the primary's share of the ring, 0–1) paired with a derived secondary.
    /// Sane range: 0.5–0.75.
    static let derivedBalance = 0.65
    /// Range the primary's share of the ring is clamped to, so neither color all but vanishes.
    /// Sane range: lower bound 0.25–0.45, upper bound 0.65–0.85.
    static let balanceRange: ClosedRange<Double> = 0.35...0.8

    /// Minimum HSB brightness (0–1) of both palette colors. The palette is light on a dark screen
    /// edge, so a navy cover should glow bright blue, not murky blue. Sane range: 0.7–0.95.
    static let minBrightness = 0.85
    /// Minimum HSB saturation (0–1) of both palette colors. Low enough that pastel and muted
    /// covers glow soft, as they look, rather than being pushed vivid; high enough that their
    /// light still reads as tinted. Sane range: 0.2–0.5.
    static let minSaturation = 0.3

    /// Black-and-white (and nearly so) artwork glows white and silver, keeping the cover's own
    /// slight tint — a sepia print gives warm white. L* of the white and of the silver.
    /// Sane ranges: 92–100 and 70–88.
    static let monochromeLightness = 97.0
    static let monochromeSecondaryLightness = 80.0
    /// How strongly the cover's average tint carries into the whites, and the most chroma it may
    /// add, so the result stays white. Sane ranges: 1–3 and 4–12.
    static let monochromeTintGain = 1.5
    static let monochromeMaxTint = 8.0
    /// The silver leans slightly cool (negative b* is bluer), so the two whites differ as they
    /// drift around the screen. Sane range: -8–0.
    static let monochromeSilverCoolness = -4.0
    /// The white's share of the ring. Sane range: 0.5–0.75.
    static let monochromeBalance = 0.6
}

/// Derives a glow palette from album artwork.
///
/// The artwork is shrunk to at most 64×64, converted to CIELAB, pooled into a fine histogram and
/// clustered with k-means (k = 5, deterministic seeds, a bounded number of passes). Neutral
/// clusters (black, white, gray) are dropped; the rest are made glow-ready (bright, somewhat
/// saturated, same hue) and grouped into families of look-alike colors. Families too small to be
/// more than noise are dropped and the rest ranked by share weighted by vividness. The best vivid
/// family (failing that, the best muted one) is the primary and the next best family the
/// secondary; with no second family, the secondary is the primary with its hue rotated. Artwork
/// with no color at all glows white and silver in its own slight tint.
///
/// Pure and deterministic, with no shared state or randomness: safe to call from any thread,
/// concurrently, and the same artwork always yields the same palette. EXIF orientation is ignored
/// on purpose, since rotating an image doesn't change its colors.
enum ColorExtractor {
    enum Source: Equatable, Sendable {
        /// The palette leads with a color the artwork shows vividly.
        case artwork
        /// The artwork is only weakly colored (muted, sepia, pastel); the palette lifts its tint
        /// to glow strength.
        case boosted
        /// The artwork is black and white (or nearly): a white and a silver, in its own tint.
        case monochrome
        /// Nothing visible to read (fully transparent or empty): `GlowPalette.fallback`.
        case fallback
    }

    struct Result: Equatable, Sendable {
        var palette: GlowPalette
        var source: Source
    }

    /// nil only when the data can't be decoded as an image.
    static func extract(fromImageData data: Data) -> Result? {
        // The decoder autoreleases some of its objects; the pool frees them as this call returns
        // rather than whenever the calling thread (possibly a Swift concurrency one) drains next.
        autoreleasepool {
            // NSBitmapImageRep decodes every still-image format the system knows (JPEG, PNG, HEIC,
            // TIFF, GIF's first frame…), lazily: drawing it small in `samples(of:)` lets JPEG
            // decode at reduced size. A fresh rep per call, so nothing is shared between threads.
            guard let image = NSBitmapImageRep(data: data)?.cgImage else { return nil }
            return extract(from: image)
        }
    }

    static func extract(from image: CGImage) -> Result {
        palette(from: clusters(of: pooled(samples(of: image), cellSize: ColorExtractorConfig.poolCellSize)))
    }
}

// MARK: - Sampling

extension ColorExtractor {
    /// The image's visible pixels in Lab, weighted by opacity, after shrinking it to at most
    /// `sampleSide` on each side. Never upsamples, so a 1×1 image yields one sample.
    private static func samples(of image: CGImage) -> [WeightedColor] {
        let width = min(image.width, ColorExtractorConfig.sampleSide)
        let height = min(image.height, ColorExtractorConfig.sampleSide)
        guard width > 0, height > 0, let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            // Drawing into an 8-bit premultiplied RGBA sRGB bitmap converts whatever the source is
            // (CMYK, gray, indexed, 16-bit, float, P3, with or without alpha) and downsamples it
            // in the same pass. The squash to a square doesn't matter: both axes scale uniformly,
            // so every color keeps its share of the area.
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Averages neighboring pixels rather than picking one, so fine detail isn't aliased away.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }

        var samples: [WeightedColor] = []
        samples.reserveCapacity(width * height)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[offset + 3])
            guard alpha > 0, alpha / 255 >= ColorExtractorConfig.minAlpha else { continue }
            // Premultiplied channel ÷ alpha, both 0–255, is the straight channel in 0...1.
            let color = PaletteColor(
                red: Double(bytes[offset]) / alpha,
                green: Double(bytes[offset + 1]) / alpha,
                blue: Double(bytes[offset + 2]) / alpha
            )
            samples.append(WeightedColor(color: Lab(color), weight: alpha / 255))
        }
        return samples
    }
}

// MARK: - Clustering

extension ColorExtractor {
    /// A color standing for `weight` fully opaque samples.
    private struct WeightedColor {
        var color: Lab
        var weight: Double
    }

    /// A k-means cluster: its mean color and its fraction of the total sample weight.
    private struct Cluster {
        var color: Lab
        var share: Double
    }

    /// Pools colors into a Lab histogram with `cellSize`-wide cells: one weighted color per
    /// occupied cell, at its members' weighted mean, in cell order.
    private static func pooled(_ colors: [WeightedColor], cellSize: Double) -> [WeightedColor] {
        // One index function for all three axes: L* spans 0–100 and a*, b* stay within ±128 for
        // any sRGB color, so offsetting by 128 keeps every index in range.
        let cellsPerAxis = Int((256 / cellSize).rounded(.up)) + 1
        func axisIndex(_ value: Double) -> Int {
            min(max(Int(((value + 128) / cellSize).rounded(.down)), 0), cellsPerAxis - 1)
        }

        // Weighted sums per cell; divided by the weight on the way out.
        var cells: [Int: WeightedColor] = [:]
        for entry in colors {
            let key = (axisIndex(entry.color.l) * cellsPerAxis + axisIndex(entry.color.a)) * cellsPerAxis
                + axisIndex(entry.color.b)
            let cell = cells[key] ?? WeightedColor(color: .zero, weight: 0)
            cells[key] = WeightedColor(color: cell.color + entry.color * entry.weight, weight: cell.weight + entry.weight)
        }
        // Dictionary order varies between runs; key order doesn't.
        return cells.sorted { $0.key < $1.key }.map { _, cell in
            WeightedColor(color: cell.color / cell.weight, weight: cell.weight)
        }
    }

    /// Weighted Lloyd's k-means in Lab, from deterministic seeds.
    private static func clusters(of colors: [WeightedColor]) -> [Cluster] {
        var centroids = seeds(for: colors)
        guard !centroids.isEmpty else { return [] }

        var assignments = [Int](repeating: -1, count: colors.count)
        var weights = [Double](repeating: 0, count: centroids.count)
        for _ in 0..<ColorExtractorConfig.maxIterations {
            var sums = [Lab](repeating: .zero, count: centroids.count)
            weights = [Double](repeating: 0, count: centroids.count)
            var changed = false
            for (index, entry) in colors.enumerated() {
                var nearest = 0
                var nearestDistance = Double.infinity
                for (candidate, centroid) in centroids.enumerated() {
                    let distance = entry.color.squaredDistance(to: centroid)
                    if distance < nearestDistance {
                        nearest = candidate
                        nearestDistance = distance
                    }
                }
                if assignments[index] != nearest {
                    assignments[index] = nearest
                    changed = true
                }
                sums[nearest] = sums[nearest] + entry.color * entry.weight
                weights[nearest] += entry.weight
            }
            for index in centroids.indices where weights[index] > 0 {
                centroids[index] = sums[index] / weights[index]
            }
            if !changed { break }
        }

        let total = weights.reduce(0, +)
        return centroids.indices.compactMap { index in
            weights[index] > 0 ? Cluster(color: centroids[index], share: weights[index] / total) : nil
        }
    }

    /// Up to `clusterCount` seeds: the most populated cells of a coarse Lab histogram, skipping
    /// any cell too close to a seed already taken. Unlike random or farthest-point seeding, this
    /// starts on the artwork's dominant colors rather than on stray outlier pixels, and is the
    /// same for the same input.
    private static func seeds(for colors: [WeightedColor]) -> [Lab] {
        let config = ColorExtractorConfig.self
        let cells = pooled(colors, cellSize: config.seedCellSize).sorted { $0.weight > $1.weight }
        var seeds: [Lab] = []
        for cell in cells where seeds.count < config.clusterCount {
            if seeds.allSatisfy({ $0.distance(to: cell.color) >= config.seedSeparation }) {
                seeds.append(cell.color)
            }
        }
        return seeds
    }
}

// MARK: - Palette

extension ColorExtractor {
    /// One or more clusters whose glow-ready colors look alike. `color` is the highest-ranked
    /// member's; `share` and `score` add up over all members.
    private struct Family {
        var color: PaletteColor
        var lab: Lab
        var share: Double
        var score: Double
        var isVivid: Bool
    }

    private static func palette(from clusters: [Cluster]) -> Result {
        let config = ColorExtractorConfig.self

        var families: [Family] = []
        for member in clusters.compactMap(family(for:)).sorted(by: { $0.score > $1.score }) {
            if let index = families.firstIndex(where: { $0.lab.distance(to: member.lab) < config.distinctDeltaE }) {
                families[index].share += member.share
                families[index].score += member.score
                families[index].isVivid = families[index].isVivid || member.isVivid
            } else {
                families.append(member)
            }
        }
        families = families.filter { $0.share >= config.minColorShare }.sorted { $0.score > $1.score }

        // A vivid color leads whenever the artwork has one, even if a muted one covers more.
        guard let primaryIndex = families.firstIndex(where: \.isVivid) ?? families.indices.first else {
            return clusters.isEmpty ? Result(palette: .fallback, source: .fallback) : monochrome(from: clusters)
        }
        let primary = families.remove(at: primaryIndex)
        let source: Source = primary.isVivid ? .artwork : .boosted

        guard let secondary = families.first else {
            let palette = GlowPalette(
                primary: primary.color, secondary: hueShifted(primary.color), balance: config.derivedBalance
            )
            return Result(palette: palette, source: source)
        }
        let share = primary.share / (primary.share + secondary.share)
        let balance = min(max(share, config.balanceRange.lowerBound), config.balanceRange.upperBound)
        let palette = GlowPalette(primary: primary.color, secondary: secondary.color, balance: balance)
        return Result(palette: palette, source: source)
    }

    /// White and silver, carrying the artwork's average tint (share-weighted mean a*, b*),
    /// amplified a little but capped so it stays white.
    private static func monochrome(from clusters: [Cluster]) -> Result {
        let config = ColorExtractorConfig.self
        var a = 0.0, b = 0.0
        for cluster in clusters {
            a += cluster.color.a * cluster.share
            b += cluster.color.b * cluster.share
        }
        let chroma = (a * a + b * b).squareRoot()
        let scale = chroma > 0 ? min(chroma * config.monochromeTintGain, config.monochromeMaxTint) / chroma : 0
        let white = Lab(l: config.monochromeLightness, a: a * scale, b: b * scale)
        let silver = Lab(l: config.monochromeSecondaryLightness, a: a * scale, b: b * scale + config.monochromeSilverCoolness)
        let palette = GlowPalette(primary: white.rgb, secondary: silver.rgb, balance: config.monochromeBalance)
        return Result(palette: palette, source: .monochrome)
    }

    /// A single-cluster family, or nil for a cluster too neutral to color the glow.
    private static func family(for cluster: Cluster) -> Family? {
        let config = ColorExtractorConfig.self
        let chroma = cluster.color.chroma
        let isVivid = chroma >= config.vividChroma
        guard chroma >= config.neutralChroma else { return nil }
        guard isVivid || (config.nearBlackLightness...config.nearWhiteLightness).contains(cluster.color.l) else {
            return nil
        }
        let glow = glowReady(cluster.color.rgb)
        let vividness = min(chroma / config.fullWeightChroma, 1)
        return Family(color: glow, lab: Lab(glow), share: cluster.share, score: cluster.share * vividness, isVivid: isVivid)
    }

    /// Same hue, with brightness and saturation raised to at least the configured floors.
    private static func glowReady(_ color: PaletteColor) -> PaletteColor {
        var hsb = HSB(color)
        hsb.saturation = max(hsb.saturation, ColorExtractorConfig.minSaturation)
        hsb.brightness = max(hsb.brightness, ColorExtractorConfig.minBrightness)
        return hsb.rgb
    }

    private static func hueShifted(_ color: PaletteColor) -> PaletteColor {
        var hsb = HSB(color)
        hsb.hue += ColorExtractorConfig.derivedHueShiftDegrees / 360
        return hsb.rgb
    }
}

// MARK: - Color spaces

extension ColorExtractor {
    /// A CIELAB color relative to the D65 white point: the perceptual space the clustering runs
    /// in, where straight-line distance (ΔE*76) roughly tracks how different two colors look.
    struct Lab: Equatable, Sendable {
        var l: Double
        var a: Double
        var b: Double

        static let zero = Lab(l: 0, a: 0, b: 0)

        // D65 reference white in XYZ, and CIE's exact ε = 216/24389 and κ = 24389/27, which join
        // the cube-root and linear segments of the Lab transfer function without a kink.
        private static let whiteX = 0.95047
        private static let whiteZ = 1.08883
        private static let epsilon = 216.0 / 24389
        private static let kappa = 24389.0 / 27

        init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }

        /// sRGB → linear sRGB → XYZ (D65) → CIELAB.
        init(_ color: PaletteColor) {
            let red = Self.linear(color.red)
            let green = Self.linear(color.green)
            let blue = Self.linear(color.blue)
            // The sRGB primaries' XYZ matrix (IEC 61966-2-1), normalized to the white point.
            let x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / Self.whiteX
            let y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
            let z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / Self.whiteZ
            let fx = Self.labF(x)
            let fy = Self.labF(y)
            let fz = Self.labF(z)
            self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
        }

        /// Back to sRGB, clipped to its gamut.
        var rgb: PaletteColor {
            let fy = (l + 16) / 116
            let x = Self.labFInverse(fy + a / 500) * Self.whiteX
            let y = Self.labFInverse(fy)
            let z = Self.labFInverse(fy - b / 200) * Self.whiteZ
            let red = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
            let green = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
            let blue = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
            return PaletteColor(red: Self.gamma(red), green: Self.gamma(green), blue: Self.gamma(blue))
        }

        /// Distance from the gray axis: 0 for black, white and every gray.
        var chroma: Double { (a * a + b * b).squareRoot() }

        func squaredDistance(to other: Lab) -> Double {
            let dl = l - other.l, da = a - other.a, db = b - other.b
            return dl * dl + da * da + db * db
        }

        /// ΔE*76.
        func distance(to other: Lab) -> Double { squaredDistance(to: other).squareRoot() }

        static func + (lhs: Lab, rhs: Lab) -> Lab { Lab(l: lhs.l + rhs.l, a: lhs.a + rhs.a, b: lhs.b + rhs.b) }
        static func * (lhs: Lab, rhs: Double) -> Lab { Lab(l: lhs.l * rhs, a: lhs.a * rhs, b: lhs.b * rhs) }
        static func / (lhs: Lab, rhs: Double) -> Lab { Lab(l: lhs.l / rhs, a: lhs.a / rhs, b: lhs.b / rhs) }

        /// sRGB transfer curve, decoded.
        private static func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        /// sRGB transfer curve, encoded (clipping out-of-gamut values first).
        private static func gamma(_ value: Double) -> Double {
            let clipped = min(max(value, 0), 1)
            return clipped <= 0.0031308 ? clipped * 12.92 : 1.055 * pow(clipped, 1 / 2.4) - 0.055
        }

        /// CIELAB's f(t): a cube root, with a linear segment near zero where the root is too steep.
        private static func labF(_ t: Double) -> Double {
            t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
        }

        private static func labFInverse(_ f: Double) -> Double {
            let cube = f * f * f
            return cube > epsilon ? cube : (116 * f - 16) / kappa
        }
    }

    /// Hue (0..<1 for a full turn), saturation and brightness (0...1), as in `NSColor`'s HSB
    /// model. The glow adjustments happen here, since raising saturation and brightness in HSB
    /// leaves the hue exactly where it was.
    struct HSB: Equatable, Sendable {
        var hue: Double
        var saturation: Double
        var brightness: Double

        init(_ color: PaletteColor) {
            let maximum = max(color.red, color.green, color.blue)
            let delta = maximum - min(color.red, color.green, color.blue)
            brightness = maximum
            saturation = maximum > 0 ? delta / maximum : 0
            guard delta > 0 else {
                hue = 0
                return
            }
            // Position around the hexcone, in sixths of a turn from red.
            let sixths: Double
            if maximum == color.red {
                sixths = (color.green - color.blue) / delta
            } else if maximum == color.green {
                sixths = 2 + (color.blue - color.red) / delta
            } else {
                sixths = 4 + (color.red - color.green) / delta
            }
            hue = sixths / 6 - (sixths / 6).rounded(.down)
        }

        var rgb: PaletteColor {
            let turn = hue - hue.rounded(.down)
            let sixths = turn * 6
            let fraction = sixths - sixths.rounded(.down)
            let value = min(max(brightness, 0), 1)
            let chroma = min(max(saturation, 0), 1)
            let p = value * (1 - chroma)
            let q = value * (1 - chroma * fraction)
            let t = value * (1 - chroma * (1 - fraction))
            switch Int(sixths) % 6 {
            case 0: return PaletteColor(red: value, green: t, blue: p)
            case 1: return PaletteColor(red: q, green: value, blue: p)
            case 2: return PaletteColor(red: p, green: value, blue: t)
            case 3: return PaletteColor(red: p, green: q, blue: value)
            case 4: return PaletteColor(red: t, green: p, blue: value)
            default: return PaletteColor(red: value, green: p, blue: q)
            }
        }
    }
}
