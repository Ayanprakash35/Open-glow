import SwiftUI

/// Each tour page's controls. Every one writes straight into `Settings`, so the glow on screen
/// follows while the tour is open.
extension OnboardingPageView {
    struct WelcomeHighlights: View {
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                OnboardingTile("Moves with the beat", systemImage: "waveform")
                OnboardingTile("Colors from album art", systemImage: "photo.on.rectangle.angled")
                OnboardingTile("Free and open source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    struct MusicSyncControls: View {
        @Bindable var settings: Settings
        let status: StatusModel
        let actions: OnboardingActions

        var body: some View {
            OnboardingCard {
                switch status.musicSync {
                case .needsPermission:
                    VStack(alignment: .leading, spacing: 10) {
                        StatusRow(
                            "Allow Screen & System Audio Recording",
                            detail: "macOS keeps your Mac's sound behind this permission. Open Glow uses it only to hear the music.",
                            systemImage: "lock.shield",
                            tint: .orange
                        )
                        HStack(spacing: 10) {
                            Button("Allow…", action: actions.grantScreenRecording)
                            Text("If macOS asks, quit and reopen Open Glow afterwards.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, StatusRow.textInset)
                    }
                case .listening(let receivingAudio):
                    StatusRow(
                        "Screen & System Audio Recording is allowed",
                        detail: receivingAudio ? "The glow is moving with what's playing right now." : "Play something and watch the edges move.",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                case .starting:
                    StatusRow(
                        "Screen & System Audio Recording is allowed",
                        detail: "Music Sync is starting up.",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                case .captureFailed, .captureUnreadable:
                    StatusRow(
                        "Allowed, but Music Sync can't hear anything yet",
                        detail: "Open Glow keeps trying. Click its menu-bar icon for details.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                case .steady:
                    HStack(spacing: 12) {
                        StatusRow(
                            "Music Sync is switched off",
                            detail: settings.animationMode == .flow ? "The glow is set to Flow, so it ignores audio." : "The glow is set to Steady, so it ignores audio.",
                            systemImage: "waveform.slash",
                            tint: .secondary
                        )
                        Button("Use Music Sync") { settings.animationMode = .musicSync }
                    }
                case .off:
                    HStack(spacing: 12) {
                        StatusRow(
                            "The glow is off",
                            detail: settings.isEnabled ? "Every display is switched off in Settings." : "Turn it on to try Music Sync.",
                            systemImage: "power",
                            tint: .secondary
                        )
                        if !settings.isEnabled {
                            Button("Turn On") { settings.isEnabled = true }
                        }
                    }
                }
            }
        }
    }

    struct AlbumColorControls: View {
        @Bindable var settings: Settings
        let status: StatusModel
        let actions: OnboardingActions

        var body: some View {
            VStack(spacing: 12) {
                Picker("Color source", selection: $settings.colorMode) {
                    Text("Album Art").tag(ColorMode.albumArt)
                    Text("Gradient").tag(ColorMode.manual)
                    Text("Presets").tag(ColorMode.preset)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                OnboardingCard {
                    switch settings.colorMode {
                    case .albumArt: players
                    case .manual: gradient
                    case .preset: presets
                    }
                }
            }
        }

        private var players: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text("Follow")
                    Toggle("Apple Music", isOn: $settings.followAppleMusic)
                    Toggle("Spotify", isOn: $settings.followSpotify)
                    Spacer(minLength: 0)
                    Button("Automation Settings…", action: actions.openAutomationSettings)
                        .buttonStyle(.link)
                        .help("Privacy & Security › Automation lists the music apps Open Glow may read.")
                }
                .toggleStyle(.checkbox)
                if case .notAuthorized(let player) = status.nowPlaying {
                    Text("Open Glow isn't allowed to read \(player.displayName) yet. Turn it on under Automation in Privacy & Security.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !settings.followAppleMusic && !settings.followSpotify {
                    Text("With no player chosen, the glow keeps its default colors.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The first time music plays, macOS asks to let Open Glow see the song and its artwork. Choose Allow — Open Glow never controls playback.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var gradient: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    ColorPicker("Color 1", selection: colorBinding(\.primary), supportsOpacity: false)
                    ColorPicker("Color 2", selection: colorBinding(\.secondary), supportsOpacity: false)
                    Spacer(minLength: 8)
                    PaletteSwatch(palette: settings.manualPalette)
                        .frame(width: 120, height: 14)
                }
                Text("Click a color to change it. The glow follows while you pick.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        private var presets: some View {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(PalettePresets.all) { preset in
                    let selected = settings.presetID == preset.id
                    Button {
                        settings.presetID = preset.id
                    } label: {
                        VStack(spacing: 4) {
                            PaletteSwatch(palette: preset.palette)
                                .frame(height: 14)
                                .padding(2)
                                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                            Text(preset.name)
                                .font(.caption)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.name) preset")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }

        private func colorBinding(_ keyPath: WritableKeyPath<GlowPalette, PaletteColor>) -> Binding<Color> {
            Binding(
                get: { Color(nsColor: settings.manualPalette[keyPath: keyPath].nsColor) },
                set: { newColor in
                    if let rgb = PaletteColor(NSColor(newColor)) {
                        settings.manualPalette[keyPath: keyPath] = rgb
                    }
                }
            )
        }
    }

    struct LookControls: View {
        @Bindable var settings: Settings
        let status: StatusModel

        var body: some View {
            VStack(spacing: 12) {
                Picker("Animation", selection: $settings.animationMode) {
                    Text("Music Sync").tag(AnimationMode.musicSync)
                    Text("Flow").tag(AnimationMode.flow)
                    Text("Steady").tag(AnimationMode.steady)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                OnboardingCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(modeExplanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Text("Brightness")
                            Image(systemName: "sun.min")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Slider(value: $settings.brightness, in: SettingsRange.brightness) {
                                Text("Brightness")
                            }
                            .labelsHidden()
                            Image(systemName: "sun.max")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text("Thickness, softness, flow speed and more are in Settings.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }

        private var modeExplanation: String {
            let explanation = switch settings.animationMode {
            case .musicSync: "Music Sync: the light swells with the beat, and flows gently between songs."
            case .flow: "Flow: the colors drift slowly around your screen. Audio is ignored."
            case .steady: "Steady: a calm, still glow. Audio is ignored."
            }
            guard status.systemReducesMotion, settings.animationMode != .steady else { return explanation }
            return explanation + " Reduce Motion is on, so the colors hold still."
        }
    }

    struct CodingSessionControls: View {
        @Bindable var settings: Settings

        var body: some View {
            OnboardingCard {
                VStack(alignment: .leading, spacing: 10) {
                    SwitchRow("Glow when a Claude Code or Codex session starts", isOn: $settings.codingSessionGlow)
                    HStack(spacing: 16) {
                        legend("Claude Code", palette: OnboardingPalettes.claude)
                        legend("Codex", palette: OnboardingPalettes.codex)
                    }
                    Text("Open Glow only notices that a session started. It never sees your code or your conversations.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func legend(_ name: String, palette: GlowPalette) -> some View {
            HStack(spacing: 6) {
                PaletteSwatch(palette: palette)
                    .frame(width: 28, height: 10)
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    struct AllSetControls: View {
        let status: StatusModel
        let actions: OnboardingActions

        var body: some View {
            OnboardingCard {
                VStack(alignment: .leading, spacing: 8) {
                    HintRow("Click the menu-bar icon for every setting.", systemImage: "cursorarrow.click")
                    HintRow("Right-click it for quick switches, and to take this tour again.", systemImage: "contextualmenu.and.cursorarrow")
                    HintRow(
                        "Timers & Pomodoro are there too: the countdown replaces the icon, and the light recedes around your screen as time runs out.",
                        systemImage: "timer"
                    )
                    Divider()
                        .padding(.vertical, 2)
                    launchAtLogin
                }
            }
        }

        private var launchAtLogin: some View {
            VStack(alignment: .leading, spacing: 4) {
                SwitchRow("Start Open Glow when you log in", isOn: Binding(
                    get: { status.launchAtLogin != .disabled },
                    set: { actions.setLaunchAtLogin($0) }
                ))
                if status.launchAtLogin == .requiresApproval {
                    HStack(spacing: 6) {
                        Text("macOS needs you to allow Open Glow in Login Items.")
                            .foregroundStyle(.secondary)
                        Button("Open Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                // Registering while approval is pending fails with "Operation not permitted", which
                // the hint above already explains.
                if status.launchAtLogin != .requiresApproval, let error = status.launchAtLoginError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
