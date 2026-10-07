import AppKit

/// Palette tuning.
enum PaletteConfig {
    /// Width of each soft transition between the two colors, as a fraction of the way around the
    /// screen. Wider reads as one smooth gradient, narrower as two distinct color zones.
    /// Sane range: 0.1–0.45.
    static let transitionFraction: Double = 0.35
}

/// An sRGB color with 0...1 components. A plain value (unlike `NSColor`/`CGColor`) so palettes can
/// be persisted, compared and handed between threads.
struct PaletteColor: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Converts any color (P3, grayscale, a named catalog color…) to sRGB; nil for colors with no
    /// RGB equivalent, such as pattern colors.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// The same color's components in `space` (an RGB space), for drawing straight into it.
    func converted(to space: CGColorSpace) -> PaletteColor {
        guard let color = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = color.components, components.count >= 3
        else { return self }
        return PaletteColor(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
    }

    /// Straight sRGB interpolation: `fraction` 0 is `self`, 1 is `other`.
    func mixed(with other: PaletteColor, fraction: Double) -> PaletteColor {
        let t = min(max(fraction, 0), 1)
        return PaletteColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }
}

/// The glow's colors: a primary and a secondary that run around the screen as one gradient.
struct GlowPalette: Hashable, Sendable, Codable {
    var primary: PaletteColor
    var secondary: PaletteColor
    /// Share of the way around the screen the primary covers, 0...1: 0.5 splits evenly, 1 shows
    /// only the primary, 0 only the secondary.
    var balance: Double

    /// Clean, soft starting colors — an icy blue-white and a pale lavender — shown before any
    /// artwork has been seen and when artwork can't be read.
    static let fallback = GlowPalette(
        primary: PaletteColor(red: 0.80, green: 0.90, blue: 1.00),
        secondary: PaletteColor(red: 0.87, green: 0.80, blue: 1.00),
        balance: 0.55
    )

    /// Both colors' components in `space`.
    func converted(to space: CGColorSpace) -> GlowPalette {
        GlowPalette(primary: primary.converted(to: space), secondary: secondary.converted(to: space), balance: balance)
    }

    struct Stop: Equatable {
        var color: PaletteColor
        /// 0...1 around the circle.
        var location: Double
    }

    /// Always this many stops, so Core Animation can cross-fade between any two palettes stop by
    /// stop (it can't interpolate gradients with different stop counts; it would jump).
    static let conicStopCount = 6

    /// Color stops for a conic gradient. It starts and ends on the primary, so there is no seam
    /// where the circle closes; the primary covers `balance` of the circle centered on the start
    /// angle, the secondary the rest, with a soft transition of up to `transition` between them.
    func conicStops(transition: Double = PaletteConfig.transitionFraction) -> [Stop] {
        let share = min(max(balance, 0), 1)
        let solid: PaletteColor? = share >= 0.999 || primary == secondary ? primary : (share <= 0.001 ? secondary : nil)
        if let solid {
            return (0..<Self.conicStopCount).map {
                Stop(color: solid, location: Double($0) / Double(Self.conicStopCount - 1))
            }
        }
        // Clamping the width to both shares keeps the stops in order: each transition fits
        // inside the zones on either side of it.
        let width = min(max(transition, 0), share, 1 - share)
        let half = share / 2
        return [
            Stop(color: primary, location: 0),
            Stop(color: primary, location: half - width / 2),
            Stop(color: secondary, location: half + width / 2),
            Stop(color: secondary, location: 1 - half - width / 2),
            Stop(color: primary, location: 1 - half + width / 2),
            Stop(color: primary, location: 1),
        ]
    }
}

/// A named, built-in palette for the Preset color mode.
struct PalettePreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let palette: GlowPalette
}

enum PalettePresets {
    static let all: [PalettePreset] = [
        PalettePreset(id: "mist", name: "Mist", palette: .fallback),
        PalettePreset(id: "dusk", name: "Dusk", palette: GlowPalette(
            primary: PaletteColor(red: 0.45, green: 0.35, blue: 0.95),
            secondary: PaletteColor(red: 0.95, green: 0.40, blue: 0.75), balance: 0.6)),
        PalettePreset(id: "lagoon", name: "Lagoon", palette: GlowPalette(
            primary: PaletteColor(red: 0.10, green: 0.80, blue: 0.80),
            secondary: PaletteColor(red: 0.25, green: 0.45, blue: 1.00), balance: 0.55)),
        PalettePreset(id: "ember", name: "Ember", palette: GlowPalette(
            primary: PaletteColor(red: 1.00, green: 0.45, blue: 0.15),
            secondary: PaletteColor(red: 0.95, green: 0.20, blue: 0.40), balance: 0.55)),
        PalettePreset(id: "aurora", name: "Aurora", palette: GlowPalette(
            primary: PaletteColor(red: 0.20, green: 0.95, blue: 0.60),
            secondary: PaletteColor(red: 0.50, green: 0.35, blue: 1.00), balance: 0.5)),
        PalettePreset(id: "citrus", name: "Citrus", palette: GlowPalette(
            primary: PaletteColor(red: 1.00, green: 0.80, blue: 0.20),
            secondary: PaletteColor(red: 0.55, green: 0.95, blue: 0.30), balance: 0.55)),
        PalettePreset(id: "rose", name: "Rose", palette: GlowPalette(
            primary: PaletteColor(red: 1.00, green: 0.45, blue: 0.65),
            secondary: PaletteColor(red: 0.75, green: 0.40, blue: 1.00), balance: 0.5)),
        PalettePreset(id: "glacier", name: "Glacier", palette: GlowPalette(
            primary: PaletteColor(red: 0.55, green: 0.85, blue: 1.00),
            secondary: PaletteColor(red: 0.92, green: 0.96, blue: 1.00), balance: 0.6)),
    ]

    static let defaultID = "mist"

    /// The preset with `id`, or the default one if that id no longer exists.
    static func preset(withID id: String) -> PalettePreset {
        all.first { $0.id == id } ?? all[0]
    }
}
