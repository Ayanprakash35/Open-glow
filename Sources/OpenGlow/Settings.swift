import Foundation

/// How the top edge glow behaves on displays with a camera-housing notch.
enum NotchMode: String {
    /// Route the top edge's path down and around the notch, hugging its actual outline.
    case curveAround
    /// Draw the top edge as a plain straight line, ignoring the notch entirely.
    case ignore
}

/// How the glow moves.
enum AnimationMode: String {
    /// Reacts to system audio; flows gently while nothing plays.
    case musicSync
    /// Colors drift slowly around the screen; audio is ignored — no capture, no FFT.
    case flow
    /// Holds still; audio is ignored.
    case steady
}

/// Where the glow's colors come from.
enum ColorMode: String, CaseIterable {
    /// Two colors picked from the now-playing track's artwork (Music or Spotify).
    case albumArt
    /// The user's own two colors and balance.
    case manual
    /// One of `PalettePresets`.
    case preset
}

/// Slider ranges for the numeric settings.
enum SettingsRange {
    /// Peak opacity of the light at the edge.
    static let brightness: ClosedRange<Double> = 0.2...1
    /// Main falloff length in points.
    static let thickness: ClosedRange<Double> = 4...40
    /// Share of the light in the faint tail.
    static let softness: ClosedRange<Double> = 0...0.7
    /// How strongly music moves the glow; 0.5 is the tuned default (see `GlowMotionConfig`).
    static let reactivity: ClosedRange<Double> = 0...1
    /// Multiplier on how fast the colors flow around the screen.
    static let flowSpeed: ClosedRange<Double> = 0.25...3
}

/// Every persisted preference, in one observable store: the popover binds to it directly and the
/// right-click menu reads and writes it too, so both always agree. Each property persists to
/// `UserDefaults` as it's set and reports what changed through `onChange`, so the glow updates
/// live while a slider is dragged.
@MainActor
@Observable
final class Settings {
    static let shared: Settings = {
        migrateFromGlowbar(into: .standard)
        return Settings()
    }()

    enum Change {
        case enabled, animationMode, stereoMode, notchMode, displays
        case colorMode, manualPalette, preset
        case shape, reactivity, flowSpeed
        case players, codingSessionGlow, onboarding
    }

    /// Called after any setting changes, with what changed.
    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let isEnabled = "isEnabled"
        static let animationMode = "animationMode"
        static let stereoMode = "stereoModeEnabled"
        static let notchMode = "notchMode"
        static let disabledDisplays = "disabledDisplayUUIDs"
        static let colorMode = "colorMode"
        static let manualPalette = "manualPalette"
        static let preset = "presetID"
        // The edge light reads these differently from the earlier ring glow, so they're new keys
        // rather than reinterpretations of old values.
        static let brightness = "edgeBrightness"
        static let thickness = "edgeThickness"
        static let softness = "edgeSoftness"
        static let reactivity = "reactivity"
        static let flowSpeed = "flowSpeed"
        static let followAppleMusic = "followAppleMusic"
        static let followSpotify = "followSpotify"
        static let codingSessionGlow = "codingSessionGlow"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let migratedFromGlowbar = "migratedFromGlowbar"
    }

    /// The master on/off switch.
    var isEnabled: Bool {
        didSet { persist(isEnabled, Key.isEnabled, changed: isEnabled != oldValue, .enabled) }
    }

    var animationMode: AnimationMode {
        didSet { persist(animationMode.rawValue, Key.animationMode, changed: animationMode != oldValue, .animationMode) }
    }

    /// Left channel drives the left edge, right drives the right edge, both drive top/bottom.
    var stereoModeEnabled: Bool {
        didSet { persist(stereoModeEnabled, Key.stereoMode, changed: stereoModeEnabled != oldValue, .stereoMode) }
    }

    var notchMode: NotchMode {
        didSet { persist(notchMode.rawValue, Key.notchMode, changed: notchMode != oldValue, .notchMode) }
    }

    /// Only explicitly disabled displays are stored, so a display nobody has touched yet
    /// (including one connected for the first time) shows the glow.
    private(set) var disabledDisplayUUIDs: Set<String> {
        didSet { persist(Array(disabledDisplayUUIDs), Key.disabledDisplays, changed: disabledDisplayUUIDs != oldValue, .displays) }
    }

    var colorMode: ColorMode {
        didSet { persist(colorMode.rawValue, Key.colorMode, changed: colorMode != oldValue, .colorMode) }
    }

    /// The user's own gradient for the Manual color mode.
    var manualPalette: GlowPalette {
        didSet {
            let data = try? JSONEncoder().encode(manualPalette)
            persist(data, Key.manualPalette, changed: manualPalette != oldValue, .manualPalette)
        }
    }

    var presetID: String {
        didSet { persist(presetID, Key.preset, changed: presetID != oldValue, .preset) }
    }

    /// Peak opacity of the light at the edge.
    var brightness: Double {
        didSet { persist(brightness, Key.brightness, changed: brightness != oldValue, .shape) }
    }

    /// How far inward the light reaches.
    var thickness: Double {
        didSet { persist(thickness, Key.thickness, changed: thickness != oldValue, .shape) }
    }

    /// How much of the light is in the soft, faint tail (the bloom).
    var softness: Double {
        didSet { persist(softness, Key.softness, changed: softness != oldValue, .shape) }
    }

    var reactivity: Double {
        didSet { persist(reactivity, Key.reactivity, changed: reactivity != oldValue, .reactivity) }
    }

    /// How fast the colors flow around the screen.
    var flowSpeed: Double {
        didSet { persist(flowSpeed, Key.flowSpeed, changed: flowSpeed != oldValue, .flowSpeed) }
    }

    /// Album colors follow these players.
    var followAppleMusic: Bool {
        didSet { persist(followAppleMusic, Key.followAppleMusic, changed: followAppleMusic != oldValue, .players) }
    }

    var followSpotify: Bool {
        didSet { persist(followSpotify, Key.followSpotify, changed: followSpotify != oldValue, .players) }
    }

    /// A flowing glow in the tool's colors whenever a Claude Code or Codex session starts.
    var codingSessionGlow: Bool {
        didSet { persist(codingSessionGlow, Key.codingSessionGlow, changed: codingSessionGlow != oldValue, .codingSessionGlow) }
    }

    /// Whether the welcome tour has been shown (it opens by itself until then).
    var hasCompletedOnboarding: Bool {
        didSet { persist(hasCompletedOnboarding, Key.hasCompletedOnboarding, changed: hasCompletedOnboarding != oldValue, .onboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        animationMode = defaults.string(forKey: Key.animationMode).flatMap(AnimationMode.init) ?? .musicSync
        stereoModeEnabled = defaults.bool(forKey: Key.stereoMode)
        notchMode = defaults.string(forKey: Key.notchMode).flatMap(NotchMode.init) ?? .curveAround
        disabledDisplayUUIDs = Set(defaults.stringArray(forKey: Key.disabledDisplays) ?? [])
        colorMode = defaults.string(forKey: Key.colorMode).flatMap(ColorMode.init) ?? .albumArt
        manualPalette = defaults.data(forKey: Key.manualPalette).flatMap { try? JSONDecoder().decode(GlowPalette.self, from: $0) }
            ?? .fallback
        presetID = PalettePresets.preset(withID: defaults.string(forKey: Key.preset) ?? PalettePresets.defaultID).id
        brightness = Self.number(defaults, Key.brightness, default: GlowDefaults.brightness, in: SettingsRange.brightness)
        thickness = Self.number(defaults, Key.thickness, default: GlowDefaults.thickness, in: SettingsRange.thickness)
        softness = Self.number(defaults, Key.softness, default: GlowDefaults.softness, in: SettingsRange.softness)
        reactivity = Self.number(defaults, Key.reactivity, default: 0.5, in: SettingsRange.reactivity)
        flowSpeed = Self.number(defaults, Key.flowSpeed, default: 1, in: SettingsRange.flowSpeed)
        followAppleMusic = defaults.object(forKey: Key.followAppleMusic) as? Bool ?? true
        followSpotify = defaults.object(forKey: Key.followSpotify) as? Bool ?? true
        codingSessionGlow = defaults.object(forKey: Key.codingSessionGlow) as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    func isDisplayEnabled(uuid: String) -> Bool {
        !disabledDisplayUUIDs.contains(uuid)
    }

    func setDisplayEnabled(_ enabled: Bool, uuid: String) {
        if enabled {
            disabledDisplayUUIDs.remove(uuid)
        } else {
            disabledDisplayUUIDs.insert(uuid)
        }
    }

    /// The palette the Manual or Preset mode shows; album art is resolved by `ColorCoordinator`.
    var chosenPalette: GlowPalette {
        colorMode == .preset ? PalettePresets.preset(withID: presetID).palette : manualPalette
    }

    /// The app was called Glowbar (bundle ID com.glowbar.app) before it was renamed, and macOS
    /// keeps preferences per bundle ID. Copies the old preferences over once, so the rename
    /// doesn't reset anyone's choices. The welcome tour still shows, since it covers new things.
    static func migrateFromGlowbar(into defaults: UserDefaults, from legacy: UserDefaults? = UserDefaults(suiteName: "com.glowbar.app")) {
        guard !defaults.bool(forKey: Key.migratedFromGlowbar) else { return }
        defaults.set(true, forKey: Key.migratedFromGlowbar)
        guard let legacy else { return }
        let keys = [
            Key.isEnabled, Key.animationMode, Key.stereoMode, Key.notchMode, Key.disabledDisplays,
            Key.colorMode, Key.manualPalette, Key.preset, Key.brightness, Key.thickness, Key.softness,
            Key.reactivity, Key.flowSpeed,
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    private func persist(_ value: Any?, _ key: String, changed: Bool, _ change: Change) {
        guard changed else { return }
        defaults.set(value, forKey: key)
        onChange?(change)
    }

    /// A stored number clamped to its slider range, so a hand-edited or stale default can't push
    /// the glow somewhere the UI can't reach.
    private static func number(_ defaults: UserDefaults, _ key: String, default fallback: CGFloat, in range: ClosedRange<Double>) -> Double {
        let stored = defaults.object(forKey: key) as? Double ?? Double(fallback)
        return min(max(stored.isFinite ? stored : Double(fallback), range.lowerBound), range.upperBound)
    }
}
