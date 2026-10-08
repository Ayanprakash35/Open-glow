import AppKit
import SwiftUI
import Testing
@testable import OpenGlow

/// The tour's page order and its window's ways out. The window is never put on screen.
@Suite("Onboarding")
@MainActor
struct OnboardingTests {
    @Test func pagesRunInOrder() {
        let pages = OnboardingPage.allCases
        #expect(pages.first == .welcome)
        #expect(pages.last == .allSet)
        for (index, page) in pages.enumerated() {
            #expect(page.previous == (index > 0 ? pages[index - 1] : nil))
            #expect(page.next == (index < pages.count - 1 ? pages[index + 1] : nil))
            #expect(page.isLast == (index == pages.count - 1))
        }
    }

    /// The window doesn't scroll or resize, so each page in its tallest state must fit above the
    /// navigation bar.
    @Test func everyPageFitsTheWindow() throws {
        _ = NSApplication.shared
        let available = OnboardingLayout.size.height - OnboardingLayout.navigationBarHeight - 1
        for variant in OnboardingVariant.all {
            let (settings, status) = try variant.make()
            let page = OnboardingPageView(page: variant.page, settings: settings, status: status, actions: .inert)
                .frame(width: OnboardingLayout.size.width)
            let height = NSHostingView(rootView: page).fittingSize.height
            #expect(height <= available, "\(variant.name) needs \(height) pt; \(available) pt available")
        }
    }

    @Test func illustrationMotionFollowsAnimationMode() {
        #expect(IllustrationMotion(.musicSync) == .music)
        #expect(IllustrationMotion(.flow) == .flow)
        #expect(IllustrationMotion(.steady) == .steady)
    }

    @Test func windowIsATitledFixedSizeWindow() throws {
        let (controller, _) = try makeController()
        let window = try #require(controller.window)
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.title == "Welcome to Open Glow")
        #expect(window.contentRect(forFrameRect: window.frame).size == OnboardingLayout.size)
        #expect(!window.isReleasedWhenClosed)
    }

    @Test(arguments: [EscapeRoute.closeButton, .escape, .commandW])
    func everyWayOutFinishesOnce(route: EscapeRoute) throws {
        let (controller, finishCount) = try makeController()
        let window = try #require(controller.window)
        switch route {
        case .closeButton:
            window.performClose(nil)
        case .escape:
            #expect(window.performKeyEquivalent(with: try key("\u{1b}", keyCode: 53, modifiers: [])))
        case .commandW:
            #expect(window.performKeyEquivalent(with: try key("w", keyCode: 13, modifiers: .command)))
        }
        #expect(finishCount.value == 1)
        #expect(controller.isFinished)
        window.close()
        #expect(finishCount.value == 1)
    }

    @Test func otherKeysAreLeftAlone() throws {
        let (controller, finishCount) = try makeController()
        let window = try #require(controller.window)
        #expect(!window.performKeyEquivalent(with: try key("q", keyCode: 12, modifiers: .command)))
        #expect(!window.performKeyEquivalent(with: try key("w", keyCode: 13, modifiers: [])))
        #expect(finishCount.value == 0)
    }

    enum EscapeRoute: CaseIterable, Sendable {
        case closeButton, escape, commandW
    }

    final class Counter {
        var value = 0
    }

    private func makeController() throws -> (OnboardingWindowController, Counter) {
        _ = NSApplication.shared
        let suite = "OpenGlowOnboardingTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let counter = Counter()
        let actions = OnboardingActions(
            grantScreenRecording: {}, openAutomationSettings: {}, setLaunchAtLogin: { _ in },
            finish: { counter.value += 1 }
        )
        let controller = OnboardingWindowController(settings: Settings(defaults: defaults), status: StatusModel(), actions: actions)
        return (controller, counter)
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }
}

/// Renders every page of the tour offscreen to PNGs, in light and dark, for eyeballing layout.
/// Only runs when OPENGLOW_SNAPSHOT_DIR is set:
/// `OPENGLOW_SNAPSHOT_DIR=/tmp/shots ./Scripts/test.sh --filter OnboardingSnapshot`.
@Suite("Onboarding snapshots")
@MainActor
struct OnboardingSnapshotTests {
    nonisolated private static let outputDirectory = ProcessInfo.processInfo.environment["OPENGLOW_SNAPSHOT_DIR"]

    @Test(.enabled(if: outputDirectory != nil))
    func renderPages() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        for variant in OnboardingVariant.all {
            let (settings, status) = try variant.make()
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = OnboardingView(settings: settings, status: status, actions: .inert, startPage: variant.page)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                let size = OnboardingLayout.size
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(variant.name)-\(suffix).png"))
            }
        }
    }
}

/// Every page, plus the states that make a page tallest or change what it says.
@MainActor
private struct OnboardingVariant {
    var name: String
    var page: OnboardingPage
    var configure: (OpenGlow.Settings, StatusModel) -> Void = { _, _ in }

    func make() throws -> (OpenGlow.Settings, StatusModel) {
        let suite = "OpenGlowOnboarding.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = OpenGlow.Settings(defaults: defaults)
        let status = StatusModel()
        status.musicSync = .listening(receivingAudio: false)
        status.palette = PalettePresets.preset(withID: "dusk").palette
        configure(settings, status)
        return (settings, status)
    }

    static var all: [OnboardingVariant] {
        let track = NowPlayingMonitor.Track(player: .spotify, id: "1", title: "Midnight Drive", artist: "The Night Shift", album: "Neon")
        return [
            OnboardingVariant(name: "1-welcome", page: .welcome),
            OnboardingVariant(name: "2-music-needs-permission", page: .musicSync) { _, status in status.musicSync = .needsPermission },
            OnboardingVariant(name: "2-music-listening", page: .musicSync) { _, status in status.musicSync = .listening(receivingAudio: true) },
            OnboardingVariant(name: "2-music-steady", page: .musicSync) { settings, status in
                settings.animationMode = .flow
                status.musicSync = .steady
            },
            OnboardingVariant(name: "2-music-off", page: .musicSync) { settings, status in
                settings.isEnabled = false
                status.musicSync = .off
            },
            OnboardingVariant(name: "2-music-failed", page: .musicSync) { _, status in status.musicSync = .captureFailed(reason: "The stream stopped.") },
            OnboardingVariant(name: "3-album-idle", page: .albumColors) { _, status in status.nowPlaying = .notPlaying },
            OnboardingVariant(name: "3-album-playing", page: .albumColors) { _, status in status.nowPlaying = .playing(track) },
            OnboardingVariant(name: "3-album-denied", page: .albumColors) { _, status in status.nowPlaying = .notAuthorized(.music) },
            OnboardingVariant(name: "3-album-gradient", page: .albumColors) { settings, _ in settings.colorMode = .manual },
            OnboardingVariant(name: "3-album-presets", page: .albumColors) { settings, _ in
                settings.colorMode = .preset
                settings.presetID = "lagoon"
            },
            OnboardingVariant(name: "4-look-music", page: .lookAndMotion),
            OnboardingVariant(name: "4-look-steady-dim", page: .lookAndMotion) { settings, status in
                settings.animationMode = .steady
                settings.brightness = 0.35
                status.systemReducesMotion = true
            },
            OnboardingVariant(name: "4-look-flow-reduce-motion", page: .lookAndMotion) { settings, status in
                settings.animationMode = .flow
                status.systemReducesMotion = true
            },
            OnboardingVariant(name: "5-coding", page: .codingSessions),
            OnboardingVariant(name: "5-coding-off", page: .codingSessions) { settings, _ in settings.codingSessionGlow = false },
            OnboardingVariant(name: "5-coding-codex-off", page: .codingSessions) { settings, _ in
                settings.setCodingSessionGlow(false, for: .codex)
            },
            OnboardingVariant(name: "6-all-set", page: .allSet),
            OnboardingVariant(name: "6-all-set-approval", page: .allSet) { _, status in
                status.launchAtLogin = .requiresApproval
                status.launchAtLoginError = "The operation couldn't be completed. Operation not permitted"
            },
            OnboardingVariant(name: "6-all-set-error", page: .allSet) { _, status in
                status.launchAtLoginError = "The operation couldn't be completed. (SMAppServiceErrorDomain error 1: the app couldn't be registered as a login item.)"
            },
        ]
    }
}

extension OnboardingActions {
    static var inert: OnboardingActions {
        OnboardingActions(grantScreenRecording: {}, openAutomationSettings: {}, setLaunchAtLogin: { _ in }, finish: {})
    }
}
