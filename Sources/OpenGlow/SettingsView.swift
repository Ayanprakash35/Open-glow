import SwiftUI

/// What the popover's buttons do; `AppDelegate` supplies them.
struct SettingsActions {
    var grantScreenRecording: () -> Void
    var openScreenRecordingSettings: () -> Void
    var openAutomationSettings: () -> Void
    var retryNowPlaying: () -> Void
    var relaunch: () -> Void
    var setLaunchAtLogin: (Bool) -> Void
    var openLoginItems: () -> Void
    var quit: () -> Void
    var openTour: () -> Void = {}
}

/// The popover. Every control writes straight into `Settings`, which applies it to the glow as it
/// changes — sliders and color wells update the screen while they're being dragged.
struct SettingsView: View {
    @Bindable var settings: Settings
    let status: StatusModel
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            section("Music") { musicSection }
            section("Colors") { colorSection }
            section("Glow") { glowSection }
            section("Motion") { motionSection }
            section("Displays") { displaySection }
            footer
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Open Glow").font(.headline)
                Spacer()
                Button(action: actions.openTour) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Welcome tour")
                .accessibilityLabel("Open the welcome tour")
                Toggle("Open Glow on", isOn: $settings.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text("Ambient edge glow that reacts to system audio output — never the microphone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var musicSection: some View {
        Picker("Animation", selection: $settings.animationMode) {
            Text("Music Sync").tag(AnimationMode.musicSync)
            Text("Flow").tag(AnimationMode.flow)
            Text("Steady").tag(AnimationMode.steady)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        musicStatus
    }

    @ViewBuilder
    private var musicStatus: some View {
        switch status.musicSync {
        case .off:
            note("Open Glow is off", systemImage: "light.min")
        case .steady:
            if settings.animationMode == .flow {
                note("Flowing — audio is ignored", systemImage: "wind")
            } else {
                note("Holding still — audio is ignored", systemImage: "light.max")
            }
        case .starting:
            note("Starting Music Sync…", systemImage: "hourglass")
        case .listening(let receivingAudio):
            note(receivingAudio ? "Reacting to system audio" : "Flowing until audio plays", systemImage: "waveform")
        case .needsPermission:
            attention(
                title: "Screen & System Audio Recording access needed",
                detail: "Music Sync reads system audio through ScreenCaptureKit, which macOS puts behind this permission. Until it's granted, Open Glow shows a steady glow.",
                primary: ("Grant Access…", actions.grantScreenRecording)
            )
        case .captureFailed(let reason):
            attention(
                title: "Music Sync can't capture audio",
                detail: "\(reason) Open Glow keeps retrying and shows a steady glow meanwhile.",
                primary: ("Open Privacy & Security…", actions.openScreenRecordingSettings)
            )
        case .captureUnreadable:
            attention(
                title: "Music Sync can't read the captured audio",
                detail: "macOS is delivering audio in a form Open Glow can't read, so the glow stays idle. Relaunching Open Glow starts a fresh capture.",
                primary: ("Relaunch Open Glow", actions.relaunch),
                isPermissionProblem: false
            )
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        Picker("Color source", selection: $settings.colorMode) {
            Text("Album Art").tag(ColorMode.albumArt)
            Text("Gradient").tag(ColorMode.manual)
            Text("Presets").tag(ColorMode.preset)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch settings.colorMode {
        case .albumArt:
            albumArtStatus
            HStack(spacing: 14) {
                Text("From").font(.caption).foregroundStyle(.secondary)
                Toggle("Apple Music", isOn: $settings.followAppleMusic)
                Toggle("Spotify", isOn: $settings.followSpotify)
            }
            .font(.caption)
        case .manual:
            HStack(spacing: 10) {
                ColorPicker("Color 1", selection: colorBinding(\.primary), supportsOpacity: false)
                ColorPicker("Color 2", selection: colorBinding(\.secondary), supportsOpacity: false)
                Spacer()
                swatch(settings.manualPalette).frame(width: 90, height: 12)
            }
            .font(.caption)
            labeledSlider("Blend", value: $settings.manualPalette.balance, in: 0...1)
        case .preset:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(PalettePresets.all) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    @ViewBuilder
    private var albumArtStatus: some View {
        HStack(alignment: .center, spacing: 10) {
            swatch(status.palette).frame(width: 44, height: 12)
            switch status.nowPlaying {
            case .playing(let track):
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title.isEmpty ? "Untitled track" : track.title).lineLimit(1)
                    Text([track.artist, track.player.displayName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            case .notAuthorized(let player):
                Text("Open Glow isn't allowed to read \(player.displayName)'s artwork.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .stopped:
                Text("Paused while Open Glow is off.").font(.caption).foregroundStyle(.secondary)
            case .noPlayer, .notPlaying:
                Text("Play something in Music or Spotify to color the glow from its artwork.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if case .notAuthorized = status.nowPlaying {
            HStack {
                Button("Open Automation Settings…", action: actions.openAutomationSettings)
                Button("Try Again", action: actions.retryNowPlaying)
            }
        } else if case .playing = status.nowPlaying, status.albumArtSource == .fallback {
            Text("This artwork couldn't be read, so the default palette is showing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var glowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledSlider("Brightness", value: $settings.brightness, in: SettingsRange.brightness)
            labeledSlider("Thickness", value: $settings.thickness, in: SettingsRange.thickness)
            labeledSlider("Softness", value: $settings.softness, in: SettingsRange.softness)
        }
    }

    @ViewBuilder
    private var motionSection: some View {
        labeledSlider("Reactivity", value: $settings.reactivity, in: SettingsRange.reactivity)
            .disabled(settings.animationMode != .musicSync)
        labeledSlider("Flow speed", value: $settings.flowSpeed, in: SettingsRange.flowSpeed)
            .disabled(settings.animationMode == .steady || status.systemReducesMotion)
        Toggle("Stereo — each side follows its channel", isOn: $settings.stereoModeEnabled)
            .disabled(settings.animationMode != .musicSync)
        Toggle("Glow when a Claude Code or Codex session starts", isOn: $settings.codingSessionGlow)
        if status.systemReducesMotion {
            Text("Reduce Motion is on in Accessibility settings, so the colors hold still; music still brightens the glow.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        ForEach(status.displays) { display in
            Toggle(display.name, isOn: Binding(
                get: { settings.isDisplayEnabled(uuid: display.uuid) },
                set: { settings.setDisplayEnabled($0, uuid: display.uuid) }
            ))
        }
        if status.displays.contains(where: \.hasNotch) {
            HStack {
                Text("Notch").font(.caption)
                Picker("Notch", selection: $settings.notchMode) {
                    Text("Curve Around").tag(NotchMode.curveAround)
                    Text("Ignore").tag(NotchMode.ignore)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { status.launchAtLogin != .disabled },
                    set: { actions.setLaunchAtLogin($0) }
                ))
                Spacer()
                Button("Quit Open Glow", action: actions.quit)
            }
            if status.launchAtLogin == .requiresApproval {
                HStack(spacing: 6) {
                    Text("macOS needs you to allow Open Glow in Login Items.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Open…", action: actions.openLoginItems)
                }
            }
            if let error = status.launchAtLoginError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.caption)
    }

    /// The palette as a horizontal gradient, the primary taking its `balance` share.
    private func swatch(_ palette: GlowPalette) -> some View {
        let share = min(max(palette.balance, 0), 1)
        return Capsule()
            .fill(LinearGradient(
                stops: [
                    .init(color: Color(nsColor: palette.primary.nsColor), location: 0),
                    .init(color: Color(nsColor: palette.primary.nsColor), location: share * 0.5),
                    .init(color: Color(nsColor: palette.secondary.nsColor), location: share + (1 - share) * 0.5),
                    .init(color: Color(nsColor: palette.secondary.nsColor), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
    }

    private func presetButton(_ preset: PalettePreset) -> some View {
        let selected = settings.presetID == preset.id
        return Button {
            settings.presetID = preset.id
        } label: {
            VStack(spacing: 3) {
                swatch(preset.palette)
                    .frame(height: 14)
                    .padding(2)
                    .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private func attention(title: String, detail: String, primary: (String, () -> Void), isPermissionProblem: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(primary.0, action: primary.1)
                if isPermissionProblem {
                    Button("Relaunch Open Glow", action: actions.relaunch)
                }
            }
            if isPermissionProblem {
                Text("macOS applies a new grant after a relaunch. If Open Glow already shows as enabled but this still appears, remove it from the list with −, then relaunch and grant again — macOS can stop recognizing a rebuilt copy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
