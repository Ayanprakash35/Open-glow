import SwiftUI

/// Tuning for the welcome tour's little display with edge light.
enum OnboardingIllustrationConfig {
    /// Redraws per second while the illustration moves. Sane range: 20–60.
    static let frameRate: Double = 30
    /// How fast the colors flow around the screen, in degrees per second. Sane range: 6–40.
    static let flowSpeed: Double = 18
    /// Beats per minute of the pretend song on the music pages. Sane range: 80–140.
    static let tempo: Double = 112
    /// Seconds a beat's swell takes to rise, and to fall back. Like the real glow: a gentle rise
    /// and a long fall, so beats overlap into one flowing wave instead of thumping.
    /// Sane ranges: rise 0.2–0.6, release 0.5–1.2.
    static let swellRise: Double = 0.35
    static let swellRelease: Double = 0.75
    /// Seconds each palette shows when the illustration cycles through several. Sane range: 2–6.
    static let paletteHold: Double = 3.2
    /// Share of `paletteHold` spent blending into the next palette, 0–1. Sane range: 0.2–0.6.
    static let paletteBlend: Double = 0.4
    /// Main falloff length of the light, as a fraction of the screen's height. Exaggerated
    /// compared with the real glow so it reads at this size. Sane range: 0.04–0.12.
    static let glowLength: CGFloat = 0.07
    /// Height of the display as a fraction of its width (16:10). Sane range: 0.56–0.66.
    static let aspectRatio: CGFloat = 0.625
    /// Seconds the pretend timer takes to run out. Sane range: 6–14.
    static let timerLength: Double = 9
    /// Seconds the light takes to fill the screen again before the pretend timer restarts.
    /// Sane range: 0.8–2.
    static let timerRefill: Double = 1.4
    /// What the pretend timer counts down from, in minutes (a Pomodoro). Sane range: 5–60.
    static let timerMinutes: Double = 25
    /// Share of the perimeter over which the receding end of the light fades out, 0–1.
    /// Sane range: 0.02–0.1.
    static let timerFeather: Double = 0.05
    /// Share of the perimeter over which the light fades in at the top center, where the timer's
    /// ring starts, so there's no hard seam there. Sane range: 0–0.03.
    static let timerHeadFeather: Double = 0.012
    /// How much of the pretend timer is left while the illustration holds still (Reduce Motion,
    /// or the window in the background). Sane range: 0.3–0.8.
    static let timerStillRemaining: Double = 0.64
}

/// How the illustrated glow moves, mirroring `AnimationMode`.
enum IllustrationMotion: Equatable {
    /// Flows slowly and swells smoothly with the beats of a pretend song.
    case music
    /// Flows slowly around the screen.
    case flow
    /// Holds still.
    case steady

    init(_ mode: AnimationMode) {
        switch mode {
        case .musicSync: self = .music
        case .flow: self = .flow
        case .steady: self = .steady
        }
    }
}

/// What the Open Glow item in the pretend menu bar shows.
enum IllustrationStatusItem: Equatable {
    /// The usual icon.
    case icon
    /// A running timer: its countdown, ringed, in place of the icon, while the light recedes
    /// around the screen as the time runs out — then fills up again and repeats.
    case timer
}

/// A small desktop display whose screen edges glow, drawn with gradients only (no blur filters,
/// so it's cheap to animate and renders the same in snapshots), with the light spilling onto the
/// wall behind it the way an ambient-lit TV does. `center` sits on the wallpaper under the light,
/// like the windows the real glow is drawn over; it's handed the palette showing at that moment.
struct EdgeGlowIllustration<Center: View>: View {
    /// The glow's colors; with several, it cross-fades through them in turn.
    var palettes: [GlowPalette]
    var motion: IllustrationMotion
    /// Peak opacity of the light, as `Settings.brightness`.
    var brightness: Double = 1
    var statusItem = IllustrationStatusItem.icon
    @ViewBuilder var center: (GlowPalette) -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Inactive while the window isn't key — e.g. while System Settings is in front.
    @Environment(\.controlActiveState) private var activeState

    /// The stand's parts, as fractions of the display's width.
    private static var neckHeight: CGFloat { 0.045 }
    private static var baseHeight: CGFloat { 0.012 }

    private var isAnimated: Bool {
        !reduceMotion && activeState != .inactive && (motion != .steady || palettes.count > 1 || statusItem == .timer)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / OnboardingIllustrationConfig.frameRate, paused: !isAnimated)) { timeline in
            // While paused the timeline keeps its last date, so the picture holds where it was.
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                frame(width: proxy.size.width, time: time)
            }
        }
        .aspectRatio(1 / (OnboardingIllustrationConfig.aspectRatio + Self.neckHeight + Self.baseHeight), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusItem == .timer
            ? "A display whose edge light recedes as a timer counts down in its menu bar"
            : "A display with colored light glowing along its edges")
        .accessibilityAddTraits(.isImage)
    }

    // MARK: - Drawing

    private func frame(width: CGFloat, time: Double) -> some View {
        let height = width * OnboardingIllustrationConfig.aspectRatio
        let palette = palette(at: time)
        let swell = swell(at: time)
        let angle = motion == .steady ? -90 : (time * OnboardingIllustrationConfig.flowSpeed).truncatingRemainder(dividingBy: 360)
        let stops = palette.conicStops().map {
            Gradient.Stop(color: Color(.sRGB, red: $0.color.red, green: $0.color.green, blue: $0.color.blue), location: $0.location)
        }
        let light = AngularGradient(stops: stops, center: .center, angle: .degrees(angle))
        let remaining = timerRemaining(at: time)

        return VStack(spacing: 0) {
            display(width: width, height: height, palette: palette, light: light, swell: swell, remaining: remaining)
                .background {
                    // Light spilling onto the wall behind the display.
                    Rectangle()
                        .fill(light)
                        .mask(EllipticalGradient(stops: [
                            .init(color: .black, location: 0.45),
                            .init(color: .black.opacity(0.3), location: 0.7),
                            .init(color: .clear, location: 1),
                        ]))
                        .mask { RemainingSweep(remaining: remaining) }
                        .padding(.horizontal, -width * 0.1)
                        .padding(.vertical, -height * 0.18)
                        .opacity((0.32 + 0.2 * swell) * (0.35 + 0.65 * brightness))
                }
            stand(width: width)
        }
    }

    private func display(width: CGFloat, height: CGFloat, palette: GlowPalette, light: AngularGradient, swell: Double, remaining: Double?) -> some View {
        let bezel = max(3, height * 0.035)
        let outer = RoundedRectangle(cornerRadius: height * 0.06, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: height * 0.035, style: .continuous)
        let screenSize = CGSize(width: width - bezel * 2, height: height - bezel * 2)
        let reach = screenSize.height * OnboardingIllustrationConfig.glowLength * (1 + 0.55 * swell)
        let strength = brightness * (0.85 + 0.15 * swell)
        let menuBarHeight = max(7, screenSize.height * 0.065)

        return outer
            .fill(Color(white: 0.1))
            .overlay(outer.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
            .overlay {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.09, blue: 0.14), Color(red: 0.02, green: 0.02, blue: 0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    center(palette)
                        .padding(.top, menuBarHeight)
                    VStack(spacing: 0) {
                        menuBar(height: menuBarHeight, remaining: remaining)
                        Spacer(minLength: 0)
                    }
                    Rectangle()
                        .fill(light)
                        .mask(EdgeFalloff(size: screenSize, reach: reach))
                        .mask { RemainingSweep(remaining: remaining) }
                        .opacity(strength)
                }
                .environment(\.colorScheme, .dark)
                .frame(width: screenSize.width, height: screenSize.height)
                .clipShape(screen)
            }
            .frame(width: width, height: height)
    }

    private func menuBar(height: CGFloat, remaining: Double?) -> some View {
        HStack(spacing: height * 0.9) {
            Image(systemName: "apple.logo")
            ForEach([2.4, 1.8, 2.2], id: \.self) { length in
                Capsule().frame(width: height * length, height: height * 0.3)
            }
            Spacer(minLength: 0)
            ForEach([0.9, 1.1], id: \.self) { length in
                RoundedRectangle(cornerRadius: 1).frame(width: height * length, height: height * 0.5)
            }
            if let remaining {
                Text(Self.countdown(remaining))
                    .font(.system(size: height * 0.7, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .fixedSize()
                    .padding(.horizontal, height * 0.4)
                    .frame(height: height * 1.2)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.85), lineWidth: 0.75))
            } else {
                Image(systemName: "light.max")
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Capsule().frame(width: height * 2.6, height: height * 0.3)
        }
        .font(.system(size: height * 0.62, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.5))
        .padding(.horizontal, height * 1.1)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07))
    }

    /// The pretend timer's time left, as the menu bar shows it ("17:00"); it counts whole minutes
    /// so the digits don't blur while the demo runs fast.
    private static func countdown(_ remaining: Double) -> String {
        let minutes = Int((remaining * OnboardingIllustrationConfig.timerMinutes).rounded(.up))
        return "\(minutes):00"
    }

    private func stand(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.5), Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.13, height: width * Self.neckHeight)
            Capsule()
                .fill(Color(white: 0.6))
                .frame(width: width * 0.26, height: width * Self.baseHeight)
        }
    }

    // MARK: - Motion

    /// The palette at `time`: holds each one, then blends smoothly into the next.
    private func palette(at time: Double) -> GlowPalette {
        guard palettes.count > 1 else { return palettes.first ?? .fallback }
        let steps = time / OnboardingIllustrationConfig.paletteHold
        let whole = steps.rounded(.down)
        let index = Int(whole.truncatingRemainder(dividingBy: Double(palettes.count)))
        let blendStart = 1 - OnboardingIllustrationConfig.paletteBlend
        let raw = max(0, steps - whole - blendStart) / OnboardingIllustrationConfig.paletteBlend
        let mix = raw * raw * (3 - 2 * raw)
        let from = palettes[index]
        let to = palettes[(index + 1) % palettes.count]
        return GlowPalette(
            primary: from.primary.mixed(with: to.primary, fraction: mix),
            secondary: from.secondary.mixed(with: to.secondary, fraction: mix),
            balance: from.balance + (to.balance - from.balance) * mix
        )
    }

    /// 0...1: the share of the pretend timer left, or nil without one. It runs out over
    /// `timerLength`, then the light flows back around the screen and the timer starts over.
    private func timerRemaining(at time: Double) -> Double? {
        guard statusItem == .timer else { return nil }
        guard isAnimated else { return OnboardingIllustrationConfig.timerStillRemaining }
        let length = OnboardingIllustrationConfig.timerLength
        let phase = time.truncatingRemainder(dividingBy: length + OnboardingIllustrationConfig.timerRefill)
        guard phase > length else { return 1 - phase / length }
        let refill = (phase - length) / OnboardingIllustrationConfig.timerRefill
        return refill * refill * (3 - 2 * refill)
    }

    /// 0...1: how far the light is swelling with the pretend song. Each beat is a soft swell — a
    /// gentle rise, then a long fall that carries into the next beat — big on every other beat,
    /// small in between, the way the real glow grades beats by size.
    private func swell(at time: Double) -> Double {
        guard motion == .music, !reduceMotion else { return 0 }
        let config = OnboardingIllustrationConfig.self
        let beatLength = 60 / config.tempo
        let current = (time / beatLength).rounded(.down)
        var level = 0.0
        // A swell lasts a few beats, so the last few all contribute.
        for back in 0..<4 {
            let beat = current - Double(back)
            guard beat >= 0 else { break }
            let since = time - beat * beatLength
            let size = beat.truncatingRemainder(dividingBy: 2) == 0 ? 1.0 : 0.35
            let rise = min(since / config.swellRise, 1)
            let shape = since < config.swellRise
                ? rise * rise * (3 - 2 * rise)
                : exp(-(since - config.swellRise) / config.swellRelease)
            level = max(level, size * shape)
        }
        return level
    }
}

extension EdgeGlowIllustration where Center == EmptyView {
    init(palettes: [GlowPalette], motion: IllustrationMotion, brightness: Double = 1, statusItem: IllustrationStatusItem = .icon) {
        self.init(palettes: palettes, motion: motion, brightness: brightness, statusItem: statusItem) { _ in
            EmptyView()
        }
    }
}

/// A mask that keeps the share of the light a timer has left: clockwise from the top center,
/// the receding end fading out softly. Without a timer it keeps everything.
private struct RemainingSweep: View {
    var remaining: Double?

    var body: some View {
        if let remaining, remaining < 1 {
            let end = max(remaining, 0)
            // Both fades shrink as the ring nears empty or full, so it closes up seamlessly.
            let head = min(OnboardingIllustrationConfig.timerHeadFeather, end / 2, 1 - end)
            let feather = min(OnboardingIllustrationConfig.timerFeather, end - head)
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: head),
                    .init(color: .black, location: end - feather),
                    .init(color: .clear, location: end),
                    .init(color: .clear, location: 1),
                ],
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(270)
            )
        } else {
            Color.black
        }
    }
}

/// Opacity falling off with distance from the screen's edges, like the real edge light: a bright
/// main falloff `reach` long plus a fainter, longer tail. Each edge is one linear gradient; where
/// two overlap near a corner they add up, so corners glow a little brighter, as they do on screen.
private struct EdgeFalloff: View {
    var size: CGSize
    var reach: CGFloat

    /// Distances sampled along each edge's gradient, in multiples of `reach`.
    private static let samples: [CGFloat] = [0, 0.2, 0.45, 0.75, 1.1, 1.6, 2.2, 3, 4]
    /// Share of the light in the long tail, as `Settings.softness`.
    private static let tail: CGFloat = 0.22
    /// How much longer the tail reaches than the main falloff.
    private static let tailLength: CGFloat = 2.4

    var body: some View {
        ZStack {
            edge(length: size.height, from: .top, to: .bottom)
            edge(length: size.height, from: .bottom, to: .top)
            edge(length: size.width, from: .leading, to: .trailing)
            edge(length: size.width, from: .trailing, to: .leading)
        }
    }

    private func edge(length: CGFloat, from start: UnitPoint, to end: UnitPoint) -> some View {
        let last = Self.samples.count - 1
        let stops = Self.samples.enumerated().map { index, sample in
            let level = index == last ? 0 : (1 - Self.tail) * exp(-sample) + Self.tail * exp(-sample / Self.tailLength)
            return Gradient.Stop(color: .black.opacity(level), location: min(sample * reach / max(length, 1), 1))
        }
        return LinearGradient(stops: stops, startPoint: start, endPoint: end)
    }
}
