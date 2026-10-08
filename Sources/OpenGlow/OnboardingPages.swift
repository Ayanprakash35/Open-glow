import SwiftUI

/// Colors the tour's illustrations use.
enum OnboardingPalettes {
    /// Album-like palettes the welcome and album pages cycle through while nothing is playing.
    static let demo: [GlowPalette] = ["dusk", "lagoon", "ember", "aurora"].map {
        PalettePresets.preset(withID: $0).palette
    }

    /// A tool's colors, the very ones its coding-session sweep shows, muted while that tool's
    /// glow is off.
    @MainActor
    static func codingSession(_ tool: CodingSessionMonitor.Tool, in settings: Settings) -> GlowPalette {
        settings.glowsForCodingSession(tool) ? tool.palette : muted(tool.palette)
    }

    /// `palette` drained of most of its color, for a feature that's switched off. Done to the
    /// colors rather than with a saturation filter, so snapshots show it too.
    static func muted(_ palette: GlowPalette) -> GlowPalette {
        func gray(_ color: PaletteColor) -> PaletteColor {
            let luma = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
            return color.mixed(with: PaletteColor(red: luma, green: luma, blue: luma), fraction: 0.85)
        }
        return GlowPalette(primary: gray(palette.primary), secondary: gray(palette.secondary), balance: palette.balance)
    }
}

/// One page of the tour: its illustration, a title and a few sentences, then its controls.
struct OnboardingPageView: View {
    let page: OnboardingPage
    @Bindable var settings: Settings
    let status: StatusModel
    let actions: OnboardingActions

    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(height: OnboardingLayout.heroHeight(for: page))
                .padding(.top, 22)
                .padding(.bottom, 18)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            controls
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: OnboardingLayout.contentWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Text

    private var title: String {
        switch page {
        case .welcome: "Ambient light for your Mac"
        case .musicSync: "Moves with your music"
        case .albumColors: "Colors from the album art"
        case .lookAndMotion: "Make it yours"
        case .codingSessions: "Coding sessions"
        case .allSet: "You're all set"
        }
    }

    private var message: String {
        switch page {
        case .welcome:
            "Open Glow lights up the edges of your screen in the colors of whatever you're playing, and moves with the music. It lives in your menu bar and stays out of your way."
        case .musicSync:
            "Music Sync makes the light swell with the beat. It listens to your Mac's sound output — never the microphone — and nothing is recorded."
        case .albumColors:
            "The glow takes two colors from the cover of the song playing in Apple Music or Spotify. Prefer your own? Pick a gradient or a preset."
        case .lookAndMotion:
            "Choose how the light moves and how bright it is. Your screen changes as you go."
        case .codingSessions:
            "Open Glow can greet a new Claude Code or Codex session with a wave of light around your screen — Claude's warm orange, or Codex's cool indigo."
        case .allSet:
            "Open Glow lives in your menu bar. Here's where to find everything."
        }
    }

    // MARK: - Illustrations

    @ViewBuilder
    private var hero: some View {
        switch page {
        case .welcome:
            EdgeGlowIllustration(palettes: OnboardingPalettes.demo, motion: .music) { _ in
                DesktopWindow()
            }
        case .musicSync:
            EdgeGlowIllustration(palettes: [livePalette], motion: .music) { _ in
                CenterSymbol(name: "waveform")
            }
        case .albumColors:
            EdgeGlowIllustration(palettes: albumPagePalettes, motion: .flow) { palette in
                if settings.colorMode == .albumArt {
                    AlbumCover(palette: palette)
                } else {
                    CenterSymbol(name: settings.colorMode == .preset ? "swatchpalette" : "paintpalette")
                }
            }
        case .lookAndMotion:
            EdgeGlowIllustration(
                palettes: [livePalette],
                motion: IllustrationMotion(settings.animationMode),
                brightness: settings.brightness
            ) { _ in
                DesktopWindow()
            }
        case .codingSessions:
            EdgeGlowIllustration(
                palettes: CodingSessionMonitor.Tool.allCases.map { OnboardingPalettes.codingSession($0, in: settings) },
                motion: .flow
            ) { _ in
                TerminalWindow()
            }
        case .allSet:
            EdgeGlowIllustration(palettes: [livePalette], motion: .flow, statusItem: .timer)
        }
    }

    /// The colors on screen right now.
    private var livePalette: GlowPalette {
        settings.colorMode == .albumArt ? status.palette : settings.chosenPalette
    }

    /// The playing track's colors, or a few album-like palettes in turn while nothing plays.
    private var albumPagePalettes: [GlowPalette] {
        guard settings.colorMode == .albumArt else { return [settings.chosenPalette] }
        if case .playing = status.nowPlaying { return [status.palette] }
        return OnboardingPalettes.demo
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch page {
        case .welcome: WelcomeHighlights()
        case .musicSync: MusicSyncControls(settings: settings, status: status, actions: actions)
        case .albumColors: AlbumColorControls(settings: settings, status: status, actions: actions)
        case .lookAndMotion: LookControls(settings: settings, status: status)
        case .codingSessions: CodingSessionControls(settings: settings)
        case .allSet: AllSetControls(status: status, actions: actions)
        }
    }
}
