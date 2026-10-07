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

    @Test(.enabled(if: outputDirectory != nil))
    func renderPopoverStates() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let track = NowPlayingMonitor.Track(player: .spotify, id: "1", title: "Midnight Drive", artist: "The Night Shift", album: "Neon")
        let states: [(String, ColorMode, MusicSyncStatus, NowPlayingMonitor.Status, LaunchAtLogin.State)] = [
            ("albumart-playing", .albumArt, .listening(receivingAudio: true), .playing(track), .enabled),
            ("albumart-idle", .albumArt, .listening(receivingAudio: false), .notPlaying, .disabled),
            ("albumart-denied", .albumArt, .steady, .notAuthorized(.music), .requiresApproval),
            ("gradient", .manual, .needsPermission, .noPlayer, .disabled),
            ("presets", .preset, .captureUnreadable, .noPlayer, .disabled),
        ]
        for (name, mode, musicSync, nowPlaying, launch) in states {
            let suite = "OpenGlowSnapshot.\(name)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let settings = Settings(defaults: defaults)
            settings.colorMode = mode
            let status = StatusModel()
            status.musicSync = musicSync
            status.nowPlaying = nowPlaying
            status.launchAtLogin = launch
            status.palette = PalettePresets.preset(withID: "ember").palette
            status.displays = [
                DisplayInfo(uuid: "A", name: "Built-in Retina Display", hasNotch: true),
                DisplayInfo(uuid: "B", name: "Studio Display", hasNotch: false),
            ]
            let actions = SettingsActions(
                grantScreenRecording: {}, openScreenRecordingSettings: {}, openAutomationSettings: {},
                retryNowPlaying: {}, relaunch: {}, setLaunchAtLogin: { _ in }, openLoginItems: {}, quit: {}
            )
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = SettingsView(settings: settings, status: status, actions: actions)
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
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
                print("snapshot \(name)-\(suffix): \(Int(size.width))x\(Int(size.height))")
            }
        }
    }
}
