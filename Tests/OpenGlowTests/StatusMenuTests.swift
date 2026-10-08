import AppKit
import Testing
@testable import OpenGlow

@Suite("Right-click menu")
@MainActor
struct StatusMenuTests {
    private final class Log {
        var calls: [String] = []
    }

    private func freshSettings() -> OpenGlow.Settings {
        let name = "OpenGlowMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return Settings(defaults: defaults)
    }

    private func actions(_ log: Log) -> StatusMenu.Actions {
        StatusMenu.Actions(
            openSettings: { log.calls.append("settings") },
            grantScreenRecording: { log.calls.append("grant") },
            relaunch: { log.calls.append("relaunch") },
            previewCodingSession: { log.calls.append("preview \($0.displayName)") },
            setLaunchAtLogin: { log.calls.append("launch at login \($0)") },
            openLoginItems: { log.calls.append("login items") },
            openTour: { log.calls.append("tour") },
            quit: { log.calls.append("quit") }
        )
    }

    private func state(
        musicSync: MusicSyncStatus = .listening(receivingAudio: false),
        glowVisible: Bool = true,
        launchAtLogin: LaunchAtLogin.State = .disabled
    ) -> StatusMenu.State {
        StatusMenu.State(
            displays: [DisplayInfo(uuid: "A", name: "Built-in Retina Display", hasNotch: true)],
            musicSync: musicSync,
            glowVisible: glowVisible,
            launchAtLogin: launchAtLogin
        )
    }

    private func menu(_ settings: OpenGlow.Settings, _ state: StatusMenu.State, _ log: Log) -> NSMenu {
        StatusMenu.make(settings: settings, state: state, timerItem: NSMenuItem(title: "Timer", action: nil, keyEquivalent: ""), actions: actions(log))
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
    }

    private func submenu(_ menu: NSMenu, _ title: String) throws -> NSMenu {
        try #require(menu.item(withTitle: title)?.submenu)
    }

    private func index(_ menu: NSMenu, _ title: String) throws -> Int {
        let index = menu.indexOfItem(withTitle: title)
        try #require(index >= 0, "no item titled \(title)")
        return index
    }

    @Test func coversEveryFeatureInOrder() {
        _ = NSApplication.shared
        let menu = menu(freshSettings(), state(), Log())
        #expect(titles(menu) == [
            "Turn Off", "Settings…", "—",
            "Animation", "Colors", "Stereo Mode", "Displays", "Notch", "—",
            "Timer", "Coding Sessions", "—",
            "Launch at Login", "Welcome Tour…", "Quit Open Glow",
        ])
    }

    @Test func turnOnAndOffSettingsTourAndQuit() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        let log = Log()
        let on = menu(settings, state(), log)
        on.performActionForItem(at: try index(on, "Turn Off"))
        #expect(!settings.isEnabled)
        let off = menu(settings, state(glowVisible: false), log)
        #expect(off.items.first?.title == "Turn On")
        off.performActionForItem(at: try index(off, "Turn On"))
        #expect(settings.isEnabled)
        off.performActionForItem(at: try index(off, "Settings…"))
        off.performActionForItem(at: try index(off, "Welcome Tour…"))
        off.performActionForItem(at: try index(off, "Quit Open Glow"))
        #expect(log.calls == ["settings", "tour", "quit"])
    }

    @Test func colorsOfferTheSourcesPresetsAndPlayers() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        let colors = try submenu(menu(settings, state(), Log()), "Colors")
        let presets = PalettePresets.all.map(\.name)
        #expect(titles(colors) == ["Album Art", "Gradient", "Presets", "—"] + presets
            + ["—", "Album Art From", "Apple Music", "Spotify", "—", "Edit Gradient…"])
        #expect(colors.item(withTitle: "Album Art")?.state == .on)
        #expect(colors.item(withTitle: "Presets")?.state == .off)
        // Not ticked while presets aren't the source, even the remembered one.
        #expect(colors.items.filter { presets.contains($0.title) }.allSatisfy { $0.state == .off })
        #expect(colors.items.filter { presets.contains($0.title) }.allSatisfy { $0.image != nil })
        let header = try #require(colors.item(withTitle: "Album Art From"))
        #expect(header.isSectionHeader)
        #expect(colors.item(withTitle: "Apple Music")?.state == .on)
        #expect(colors.item(withTitle: "Spotify")?.state == .on)
    }

    @Test func choosingAPresetMakesPresetsTheSource() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        var changes: [OpenGlow.Settings.Change] = []
        settings.onChange = { changes.append($0) }
        let colors = try submenu(menu(settings, state(), Log()), "Colors")
        colors.performActionForItem(at: try index(colors, "Ember"))
        #expect(settings.colorMode == .preset)
        #expect(settings.presetID == "ember")
        // The preset is chosen before the source switches, so the glow fades once, to Ember.
        #expect(changes == [.preset, .colorMode])

        let ticked = try submenu(menu(settings, state(), Log()), "Colors")
        #expect(ticked.item(withTitle: "Ember")?.state == .on)
        #expect(ticked.item(withTitle: "Mist")?.state == .off)
        #expect(ticked.item(withTitle: "Presets")?.state == .on)
        ticked.performActionForItem(at: try index(ticked, "Album Art"))
        #expect(settings.colorMode == .albumArt)
    }

    @Test func playersAndEditGradient() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        let log = Log()
        let colors = try submenu(menu(settings, state(), log), "Colors")
        colors.performActionForItem(at: try index(colors, "Spotify"))
        #expect(!settings.followSpotify)
        #expect(settings.followAppleMusic)
        colors.performActionForItem(at: try index(colors, "Apple Music"))
        #expect(!settings.followAppleMusic)
        #expect(try submenu(menu(settings, state(), log), "Colors").item(withTitle: "Spotify")?.state == .off)

        colors.performActionForItem(at: try index(colors, "Edit Gradient…"))
        #expect(settings.colorMode == .manual)
        #expect(log.calls == ["settings"])
    }

    @Test func codingSessionsChooseToolsAndPreview() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        let log = Log()
        let sessions = try submenu(menu(settings, state(), log), "Coding Sessions")
        #expect(titles(sessions) == [
            "Glow When a Session Starts", "—", "Claude Code", "Codex", "—",
            "Preview Claude Code Glow", "Preview Codex Glow",
        ])
        #expect(sessions.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled })
        #expect(sessions.item(withTitle: "Glow When a Session Starts")?.state == .on)
        #expect(sessions.item(withTitle: "Codex")?.state == .on)

        sessions.performActionForItem(at: try index(sessions, "Codex"))
        #expect(settings.codingSessionTools == [.claudeCode])
        #expect(!settings.glowsForCodingSession(.codex))
        sessions.performActionForItem(at: try index(sessions, "Preview Codex Glow"))
        sessions.performActionForItem(at: try index(sessions, "Preview Claude Code Glow"))
        #expect(log.calls == ["preview Codex", "preview Claude Code"])

        sessions.performActionForItem(at: try index(sessions, "Glow When a Session Starts"))
        #expect(!settings.codingSessionGlow)
        let off = try submenu(menu(settings, state(), log), "Coding Sessions")
        #expect(off.item(withTitle: "Glow When a Session Starts")?.state == .off)
        // The tools keep their choice but can't be changed while the glow is off.
        #expect(off.item(withTitle: "Claude Code")?.isEnabled == false)
        #expect(off.item(withTitle: "Claude Code")?.state == .on)
        #expect(off.item(withTitle: "Codex")?.isEnabled == false)
        #expect(off.item(withTitle: "Codex")?.state == .off)
        #expect(off.item(withTitle: "Preview Codex Glow")?.isEnabled == true)
    }

    @Test func previewsNeedAVisibleGlow() throws {
        _ = NSApplication.shared
        let sessions = try submenu(menu(freshSettings(), state(glowVisible: false), Log()), "Coding Sessions")
        #expect(sessions.item(withTitle: "Preview Claude Code Glow")?.isEnabled == false)
        #expect(sessions.item(withTitle: "Preview Codex Glow")?.isEnabled == false)
        #expect(sessions.item(withTitle: "Claude Code")?.isEnabled == true)
    }

    @Test func launchAtLoginFollowsTheSystemRecord() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        let log = Log()

        let disabled = menu(settings, state(launchAtLogin: .disabled), log)
        #expect(disabled.item(withTitle: "Launch at Login")?.state == .off)
        disabled.performActionForItem(at: try index(disabled, "Launch at Login"))

        let enabled = menu(settings, state(launchAtLogin: .enabled), log)
        #expect(enabled.item(withTitle: "Launch at Login")?.state == .on)
        #expect(enabled.item(withTitle: "Allow in Login Items…") == nil)
        enabled.performActionForItem(at: try index(enabled, "Launch at Login"))

        // Registered but waiting for approval reads as on, as the popover's toggle does, with a
        // way to the approval.
        let pending = menu(settings, state(launchAtLogin: .requiresApproval), log)
        #expect(pending.item(withTitle: "Launch at Login")?.state == .on)
        let allowIndex = try index(pending, "Allow in Login Items…")
        #expect(allowIndex == (try index(pending, "Launch at Login")) + 1)
        pending.performActionForItem(at: allowIndex)
        pending.performActionForItem(at: try index(pending, "Launch at Login"))

        #expect(log.calls == ["launch at login true", "launch at login false", "login items", "launch at login false"])
    }

    @Test func attentionItemsOfferWhatHelps() throws {
        _ = NSApplication.shared
        let log = Log()
        let actions = actions(log)

        let permission = StatusMenu.attentionItems(for: .needsPermission, actions: actions)
        #expect(permission.map(\.title) == ["Music Sync needs Screen Recording access", "Grant Screen Recording Access…", "Relaunch Open Glow"])
        #expect(permission[0].isEnabled == false)
        #expect(permission[0].toolTip == "Open Glow needs Screen & System Audio Recording access for Music Sync")

        // A capture failure isn't a permission problem: no trip to Privacy & Security.
        let failed = StatusMenu.attentionItems(for: .captureFailed(reason: "The device changed."), actions: actions)
        #expect(failed.map(\.title) == ["Music Sync can't capture audio", "Relaunch Open Glow"])
        let unreadable = StatusMenu.attentionItems(for: .captureUnreadable, actions: actions)
        #expect(unreadable.map(\.title) == ["Music Sync can't read the captured audio", "Relaunch Open Glow"])

        for quiet in [MusicSyncStatus.off, .steady, .starting, .listening(receivingAudio: true)] {
            #expect(StatusMenu.attentionItems(for: quiet, actions: actions).isEmpty)
        }

        let menu = menu(freshSettings(), state(musicSync: .needsPermission), log)
        #expect(titles(menu).contains("Grant Screen Recording Access…"))
        menu.performActionForItem(at: try index(menu, "Grant Screen Recording Access…"))
        menu.performActionForItem(at: try index(menu, "Relaunch Open Glow"))
        #expect(log.calls == ["grant", "relaunch"])
    }

    /// The swatch beside each preset draws its two colors, primary on the left.
    @Test func presetSwatchesDrawThePalette() throws {
        let palette = try #require(PalettePresets.all.first { $0.id == "ember" }).palette
        let image = StatusMenu.swatch(palette)
        #expect(image.size == StatusMenuConfig.swatchSize)
        let size = StatusMenuConfig.swatchSize
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        func color(atX x: Int) throws -> PaletteColor {
            try #require(rep.colorAt(x: x, y: Int(size.height) / 2).flatMap(PaletteColor.init))
        }
        func near(_ a: PaletteColor, _ b: PaletteColor) -> Bool {
            abs(a.red - b.red) < 0.06 && abs(a.green - b.green) < 0.06 && abs(a.blue - b.blue) < 0.06
        }
        #expect(near(try color(atX: 3), palette.primary))
        #expect(near(try color(atX: Int(size.width) - 4), palette.secondary))
    }

    @Test func otherSettingsWriteThrough() throws {
        _ = NSApplication.shared
        let settings = freshSettings()
        let root = menu(settings, state(), Log())
        try submenu(root, "Animation").performActionForItem(at: 1)
        #expect(settings.animationMode == .flow)
        root.performActionForItem(at: try index(root, "Stereo Mode"))
        #expect(settings.stereoModeEnabled)
        try submenu(root, "Displays").performActionForItem(at: 0)
        #expect(!settings.isDisplayEnabled(uuid: "A"))
        try submenu(root, "Notch").performActionForItem(at: 1)
        #expect(settings.notchMode == .ignore)

        let after = menu(settings, state(), Log())
        #expect(try submenu(after, "Animation").item(withTitle: "Flow")?.state == .on)
        #expect(after.item(withTitle: "Stereo Mode")?.state == .on)
        #expect(try submenu(after, "Displays").item(withTitle: "Built-in Retina Display")?.state == .off)
    }
}

@Suite("Menu-bar icon")
struct StatusIconTests {
    @Test func offSaysWhyNothingShows() {
        let off = StatusIcon(status: .off, glowEnabled: false)
        #expect(off.description == "Open Glow — off")
        #expect(off.appearsDisabled && !off.isWarning && !off.isNormal)

        // The switch is on, so every display must be unchecked: say so and where to fix it.
        let noDisplays = StatusIcon(status: .off, glowEnabled: true)
        #expect(noDisplays.description == "Open Glow — no display is selected. Turn one on under Displays.")
        #expect(noDisplays.appearsDisabled)
        #expect(noDisplays.timerAttention == nil)
    }

    @Test func everydayStatesUseTheNormalIcon() {
        for status in [MusicSyncStatus.steady, .starting, .listening(receivingAudio: true)] {
            let icon = StatusIcon(status: status, glowEnabled: true)
            #expect(icon == StatusIcon(symbol: "light.max", description: "Open Glow", isNormal: true))
            #expect(icon.timerAttention == nil)
        }
    }

    /// A running timer's countdown carries the same warning the icon would show.
    @Test func warningsTravelWithTheTimer() {
        let cases: [(MusicSyncStatus, String)] = [
            (.needsPermission, "Open Glow needs Screen & System Audio Recording access for Music Sync"),
            (.captureFailed(reason: "Gone."), "Open Glow can't capture audio for Music Sync"),
            (.captureUnreadable, "Open Glow can't read the captured audio for Music Sync"),
        ]
        for (status, description) in cases {
            let icon = StatusIcon(status: status, glowEnabled: true)
            #expect(icon.isWarning && !icon.appearsDisabled)
            #expect(icon.description == description)
            #expect(icon.timerAttention == TimerAttention(symbol: "exclamationmark.triangle", description: description))
            #expect(status.needsAttention)
        }
    }
}

@Suite("Popover now playing")
struct NowPlayingShownTests {
    private let spotifyTrack = NowPlayingMonitor.Track(player: .spotify, id: "s", title: "S", artist: "A", album: "B")
    private let musicTrack = NowPlayingMonitor.Track(player: .music, id: "m", title: "M", artist: "A", album: "B")

    @Test func followedPlayers() {
        #expect(NowPlayingMonitor.Player.followed(appleMusic: true, spotify: true) == [.music, .spotify])
        #expect(NowPlayingMonitor.Player.followed(appleMusic: false, spotify: true) == [.spotify])
        #expect(NowPlayingMonitor.Player.followed(appleMusic: true, spotify: false) == [.music])
        #expect(NowPlayingMonitor.Player.followed(appleMusic: false, spotify: false).isEmpty)
    }

    @Test func anUnfollowedPlayerReadsAsNothingPlaying() {
        #expect(NowPlayingMonitor.Status.playing(spotifyTrack).shown(following: [.music]) == .notPlaying)
        #expect(NowPlayingMonitor.Status.playing(musicTrack).shown(following: [.spotify]) == .notPlaying)
        #expect(NowPlayingMonitor.Status.notAuthorized(.music).shown(following: [.spotify]) == .notPlaying)
        #expect(NowPlayingMonitor.Status.playing(spotifyTrack).shown(following: []) == .notPlaying)
    }

    @Test func aFollowedPlayerAndEverythingElseShowAsIs() {
        #expect(NowPlayingMonitor.Status.playing(spotifyTrack).shown(following: [.spotify]) == .playing(spotifyTrack))
        #expect(NowPlayingMonitor.Status.notAuthorized(.music).shown(following: [.music]) == .notAuthorized(.music))
        for status in [NowPlayingMonitor.Status.stopped, .noPlayer, .notPlaying] {
            #expect(status.shown(following: []) == status)
        }
    }
}
