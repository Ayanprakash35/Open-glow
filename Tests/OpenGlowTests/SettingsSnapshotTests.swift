import AppKit
import SwiftUI
import Testing
@testable import OpenGlow

/// Renders the popover offscreen to PNGs for eyeballing layout. Only runs when
/// OPENGLOW_SNAPSHOT_DIR is set: `OPENGLOW_SNAPSHOT_DIR=/tmp/shots ./Scripts/test.sh --filter Snapshot`.
@Suite("Settings popover snapshots")
@MainActor
struct SettingsSnapshotTests {
    nonisolated private static let outputDirectory = ProcessInfo.processInfo.environment["OPENGLOW_SNAPSHOT_DIR"]

    private struct PopoverState {
        var name: String
        var colorMode: ColorMode
        var musicSync: MusicSyncStatus
        var nowPlaying: NowPlayingMonitor.Status
        var launchAtLogin: LaunchAtLogin.State
        var timer: TimerSnapshot? = nil
        /// Any other settings the state needs.
        var configure: (OpenGlow.Settings) -> Void = { _ in }
    }

    @Test(.enabled(if: outputDirectory != nil))
    func renderPopoverStates() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let track = NowPlayingMonitor.Track(player: .spotify, id: "1", title: "Midnight Drive", artist: "The Night Shift", album: "Neon")
        let focus = TimerSnapshot(kind: .focus, remaining: 1_453, duration: 1_500, round: 2, rounds: 4, isPaused: false, isLastPhase: false)
        let pausedCountdown = TimerSnapshot(kind: .countdown, remaining: 671, duration: 900, round: nil, rounds: nil, isPaused: true, isLastPhase: true)
        let states = [
            PopoverState(name: "albumart-playing", colorMode: .albumArt, musicSync: .listening(receivingAudio: true), nowPlaying: .playing(track), launchAtLogin: .enabled),
            PopoverState(name: "albumart-idle", colorMode: .albumArt, musicSync: .listening(receivingAudio: false), nowPlaying: .notPlaying, launchAtLogin: .disabled),
            PopoverState(name: "albumart-denied", colorMode: .albumArt, musicSync: .steady, nowPlaying: .notAuthorized(.music), launchAtLogin: .requiresApproval),
            // Spotify plays but isn't followed: the row asks for Music instead of naming the track.
            PopoverState(name: "albumart-unfollowed", colorMode: .albumArt, musicSync: .listening(receivingAudio: true), nowPlaying: .playing(track), launchAtLogin: .enabled) {
                $0.followSpotify = false
                $0.codingSessionGlow = false
            },
            PopoverState(name: "gradient", colorMode: .manual, musicSync: .needsPermission, nowPlaying: .noPlayer, launchAtLogin: .disabled),
            PopoverState(name: "presets", colorMode: .preset, musicSync: .captureUnreadable, nowPlaying: .noPlayer, launchAtLogin: .disabled),
            PopoverState(name: "timer-focus", colorMode: .albumArt, musicSync: .listening(receivingAudio: true), nowPlaying: .playing(track), launchAtLogin: .enabled, timer: focus),
            PopoverState(
                name: "capture-failed-timer", colorMode: .manual, musicSync: .captureFailed(reason: "The audio device changed."),
                nowPlaying: .noPlayer, launchAtLogin: .disabled, timer: pausedCountdown
            ),
            PopoverState(name: "no-displays", colorMode: .preset, musicSync: .off, nowPlaying: .noPlayer, launchAtLogin: .disabled) {
                $0.setDisplayEnabled(false, uuid: "A")
                $0.setDisplayEnabled(false, uuid: "B")
            },
        ]
        let noTimerActions = TimerMenu.Actions(
            startCountdown: { _ in }, startPomodoro: { _ in }, pause: {}, resume: {},
            skipPhase: { _, _ in }, cancel: {}, askForCustomMinutes: { nil }
        )
        for state in states {
            let suite = "OpenGlowSnapshot.\(state.name)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let settings = Settings(defaults: defaults)
            settings.colorMode = state.colorMode
            state.configure(settings)
            let status = StatusModel()
            status.musicSync = state.musicSync
            status.nowPlaying = state.nowPlaying
            status.launchAtLogin = state.launchAtLogin
            status.palette = PalettePresets.preset(withID: "ember").palette
            status.displays = [
                DisplayInfo(uuid: "A", name: "Built-in Retina Display", hasNotch: true),
                DisplayInfo(uuid: "B", name: "Studio Display", hasNotch: false),
            ]
            let timer = TimerPanelModel(actions: noTimerActions)
            timer.snapshot = state.timer
            let actions = SettingsActions(
                grantScreenRecording: {}, openAutomationSettings: {},
                retryNowPlaying: {}, relaunch: {}, setLaunchAtLogin: { _ in }, openLoginItems: {}, quit: {}
            )
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = SettingsView(settings: settings, status: status, timer: timer, actions: actions)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(state.name)-\(suffix).png"))
                print("snapshot \(state.name)-\(suffix): \(Int(size.width))x\(Int(size.height))")
            }
        }
    }
}
