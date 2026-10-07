import AppKit
import SwiftUI
import os

/// Retry schedule, in seconds, after capture fails to start or stops unexpectedly. The last
/// value repeats for further attempts.
private let captureRestartDelays: [Double] = [1, 2, 5, 10]

/// A stream that ran at least this long before stopping counts as healthy: the retry schedule
/// starts over rather than continuing to back off.
private let healthyCaptureDuration: TimeInterval = 30

/// How often the open popover refreshes its status, in seconds.
private let popoverRefreshInterval: TimeInterval = 0.5

/// How often the menu-bar icon re-checks Music Sync while capture runs, in seconds (1–5). Catches
/// problems no event announces — buffers arriving unreadable — without the popover open.
private let capturingStatusRefreshInterval: TimeInterval = 2

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let logger = Logger(subsystem: "com.openglow.app", category: "App")
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let statusModel = StatusModel()
    private var popoverRefreshTimer: Timer?
    private var capturingStatusTimer: Timer?
    private var displayManager: DisplayManager!
    private var colorCoordinator: ColorCoordinator!
    private var audioEngine: AudioEngine!
    private var beatDetector: BeatDetector!

    private var isDisplayAsleep = false
    private var isSyncingAudio = false
    private var loggedMissingPermission = false
    private var restartAttempts = 0
    private var pendingRestart: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon, no app switcher entry. Set at runtime (rather than relying
        // solely on Info.plist LSUIElement) so this also holds true when launched via `swift run`
        // during development.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        setUpPopover()

        // Everything `refreshStatus()` reads exists before anything below can trigger it.
        audioEngine = AudioEngine()
        beatDetector = BeatDetector(ringBuffer: audioEngine.ringBuffer)
        displayManager = DisplayManager()
        colorCoordinator = ColorCoordinator(settings: settings, displayManager: displayManager)

        displayManager.applyBaseAppearanceToAll()
        displayManager.onDisplaysChanged = { [weak self] in self?.reconcileAudio() }
        colorCoordinator.onChange = { [weak self] in self?.refreshStatus() }
        colorCoordinator.update(animated: false)
        displayManager.playIntro()

        audioEngine.onUnexpectedStop = { [weak self] stoppedByUser, ranFor in
            self?.captureStoppedUnexpectedly(byUser: stoppedByUser, ranFor: ranFor)
        }
        audioEngine.onStartFailed = { [weak self] in
            self?.captureStoppedUnexpectedly(byUser: false, ranFor: 0)
        }
        audioEngine.onStateChange = { [weak self] in self?.captureStateChanged() }

        settings.onChange = { [weak self] change in self?.settingsChanged(change) }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(displaysDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(displaysDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspaceCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )

        // The color panel is a window of this app, so a transient popover would close the moment
        // the user clicks into it. While it's up, the popover stays until closed explicitly.
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)

        reconcileAudio()
    }

    // MARK: - Status item and popover

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let actions = SettingsActions(
            grantScreenRecording: { [weak self] in self?.grantAccess() },
            openScreenRecordingSettings: { [weak self] in self?.openPrivacySettings() },
            openAutomationSettings: { [weak self] in self?.openAutomationSettings() },
            retryNowPlaying: { [weak self] in self?.colorCoordinator.refreshNowPlaying() },
            relaunch: { [weak self] in self?.relaunch() },
            setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
            openLoginItems: { LaunchAtLogin.openLoginItemsSettings() },
            quit: { NSApp.terminate(nil) }
        )
        let host = NSHostingController(rootView: SettingsView(settings: settings, status: statusModel, actions: actions))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    @objc private func statusItemClicked(_ sender: NSStatusItem?) {
        guard let event = NSApp.currentEvent else { return }
        // Control-click is the secondary click for one-button mice and for people who turned
        // secondary click off; it must reach the menu (and Quit) too.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Opening the popover is the primary click, so it re-checks too — a grant made in
        // System Settings should take effect here, not only from the right-click menu.
        reconcileAudio()
        statusModel.launchAtLoginError = nil
        refreshStatus(includingPopoverDetails: true)
        // An accessory app isn't activated by a click on its status item, and an inactive app's
        // color panel hides immediately; activating lets the color wells work.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverRefreshTimer?.invalidate()
        popoverRefreshTimer = Timer.scheduledTimer(withTimeInterval: popoverRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverRefreshTimer?.invalidate()
        popoverRefreshTimer = nil
        popover.behavior = .transient
        // Don't create the shared color panel just to close it.
        if NSColorPanel.sharedColorPanelExists {
            NSColorPanel.shared.close()
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object is NSColorPanel, popover.isShown else { return }
        popover.behavior = .applicationDefined
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard notification.object is NSColorPanel else { return }
        popover.behavior = .transient
    }

    /// With the color panel up the popover isn't transient, so switching to another app has to
    /// close it explicitly.
    @objc private func appDidResignActive() {
        guard popover.isShown, popover.behavior == .applicationDefined else { return }
        popover.performClose(nil)
    }

    // MARK: - Menu

    private func showMenu() {
        guard let button = statusItem.button else { return }

        // There's no notification when access changes in System Settings, so every menu open
        // re-checks. That works because `checkPermission()` is a live query as long as the app
        // never calls CGRequestScreenCaptureAccess (see AudioEngine).
        reconcileAudio()

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: settings.isEnabled ? "Turn Off" : "Turn On", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(animationMenuItem())
        menu.addItem(stereoMenuItem())
        menu.addItem(displaysMenuItem())
        menu.addItem(notchMenuItem())

        let attentionItems = attentionMenuItems()
        if !attentionItems.isEmpty {
            menu.addItem(.separator())
            attentionItems.forEach(menu.addItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Open Glow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // Pop the menu at the button's location directly, rather than assigning it to
        // statusItem.menu, so left-click keeps opening the popover instead of this menu.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func animationMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, mode) in [("Music Sync", AnimationMode.musicSync), ("Flow", .flow), ("Steady", .steady)] {
            let modeItem = NSMenuItem(title: title, action: #selector(setAnimationMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode
            modeItem.state = settings.animationMode == mode ? .on : .off
            submenu.addItem(modeItem)
        }
        item.submenu = submenu
        return item
    }

    private func stereoMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Stereo Mode", action: #selector(toggleStereoMode), keyEquivalent: "")
        item.target = self
        item.state = settings.stereoModeEnabled ? .on : .off
        return item
    }

    private func displaysMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for display in displayManager.displays {
            let displayItem = NSMenuItem(title: display.name, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            displayItem.target = self
            displayItem.representedObject = display.uuid
            displayItem.state = settings.isDisplayEnabled(uuid: display.uuid) ? .on : .off
            submenu.addItem(displayItem)
        }
        item.submenu = submenu
        return item
    }

    private func notchMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Notch", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, mode) in [("Curve Around", NotchMode.curveAround), ("Ignore", .ignore)] {
            let modeItem = NSMenuItem(title: title, action: #selector(setNotchMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode
            modeItem.state = settings.notchMode == mode ? .on : .off
            submenu.addItem(modeItem)
        }
        item.submenu = submenu
        return item
    }

    /// Shown whenever Music Sync can't work — never fail silently.
    private func attentionMenuItems() -> [NSMenuItem] {
        let status = musicSyncStatus()
        guard status.needsAttention else { return [] }
        let relaunchItem = NSMenuItem(title: "Relaunch Open Glow", action: #selector(relaunch), keyEquivalent: "")
        relaunchItem.target = self
        let primary: NSMenuItem
        switch status {
        case .needsPermission:
            primary = NSMenuItem(title: "Grant Screen Recording Access…", action: #selector(grantAccess), keyEquivalent: "")
        case .captureUnreadable:
            // Not a permission problem: a fresh capture is the only thing worth offering.
            return [relaunchItem]
        default:
            primary = NSMenuItem(title: "Open Privacy & Security…", action: #selector(openPrivacySettings), keyEquivalent: "")
        }
        primary.target = self
        return [primary, relaunchItem]
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func openSettings() {
        togglePopover()
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.setDisplayEnabled(!settings.isDisplayEnabled(uuid: uuid), uuid: uuid)
    }

    @objc private func setNotchMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? NotchMode else { return }
        settings.notchMode = mode
    }

    @objc private func setAnimationMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AnimationMode else { return }
        settings.animationMode = mode
    }

    @objc private func toggleStereoMode() {
        settings.stereoModeEnabled.toggle()
    }

    // MARK: - Settings

    /// Applies a setting the moment it changes — from the popover (including mid-drag) or the menu.
    private func settingsChanged(_ change: Settings.Change) {
        switch change {
        case .enabled:
            displayManager.applyVisibility()
            colorCoordinator.update(animated: false)
            if settings.isEnabled { displayManager.playIntro() }
            reconcileAudio()
        case .animationMode:
            restartAttempts = 0
            displayManager.applyBaseAppearanceToAll()
            reconcileAudio()
        case .displays:
            displayManager.applyVisibility()
            reconcileAudio()
        case .notchMode:
            displayManager.refreshNotchMode()
        case .players:
            colorCoordinator.update(animated: true)
        case .codingSessionGlow, .onboarding:
            break
        case .stereoMode, .shape, .reactivity, .flowSpeed:
            displayManager.applyBaseAppearanceToAll()
        case .colorMode, .preset:
            colorCoordinator.update(animated: true)
        case .manualPalette:
            // Follows a color well or slider while it's dragged, so no cross-fade lag.
            colorCoordinator.update(animated: false)
        }
        refreshStatus()
    }

    @objc private func accessibilityOptionsChanged() {
        displayManager.applyBaseAppearanceToAll()
        refreshStatus()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        statusModel.launchAtLoginError = LaunchAtLogin.setEnabled(enabled)
        refreshStatus()
    }

    // MARK: - Status

    private func musicSyncStatus() -> MusicSyncStatus {
        guard displayManager.hasVisibleOverlay else { return .off }
        guard settings.animationMode == .musicSync else { return .steady }
        guard audioEngine.permissionState == .granted else { return .needsPermission }
        if audioEngine.isCapturing {
            let snapshot = beatDetector.snapshot()
            if !snapshot.hasAudio && audioEngine.droppedBufferCount > 0 {
                return .captureUnreadable
            }
            return .listening(receivingAudio: snapshot.hasAudio && !snapshot.isSilent)
        }
        if !audioEngine.isStarting, let failure = audioEngine.lastFailure {
            return .captureFailed(reason: failure.hasSuffix(".") ? failure : failure + ".")
        }
        return .starting
    }

    /// Updates the status icon and the popover's live state. The popover's details are only
    /// gathered while it's open (or about to open) — nobody sees them otherwise.
    private func refreshStatus(includingPopoverDetails: Bool = false) {
        let status = musicSyncStatus()
        statusModel.musicSync = status
        if includingPopoverDetails || popover.isShown {
            statusModel.nowPlaying = colorCoordinator.nowPlaying
            statusModel.palette = colorCoordinator.effectivePalette
            statusModel.albumArtSource = colorCoordinator.albumArtSource
            statusModel.launchAtLogin = LaunchAtLogin.state
            statusModel.displays = displayManager.displays
            statusModel.systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        switch status {
        case .off:
            symbol = "light.min"
            description = "Open Glow — off"
        case .needsPermission:
            symbol = "exclamationmark.triangle"
            description = "Open Glow needs Screen & System Audio Recording access for Music Sync"
        case .captureFailed:
            symbol = "exclamationmark.triangle"
            description = "Open Glow can't capture audio for Music Sync"
        case .captureUnreadable:
            symbol = "exclamationmark.triangle"
            description = "Open Glow can't read the captured audio for Music Sync"
        default:
            symbol = "light.max"
            description = "Open Glow"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.appearsDisabled = status == .off
        button.toolTip = description
    }

    // MARK: - Permission actions

    /// Registers Open Glow with the privacy system (which may show macOS's own prompt) and opens
    /// the Screen & System Audio Recording pane, so the click always leads somewhere visible —
    /// if access was already denied, macOS won't prompt again and the pane is the only way on.
    @objc private func grantAccess() {
        popover.performClose(nil)
        Task {
            await audioEngine.registerForScreenRecording()
            reconcileAudio()
            if audioEngine.permissionState != .granted {
                openPrivacySettings()
            }
        }
    }

    @objc private func openPrivacySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Automation is where macOS lists which apps Open Glow may send Apple Events to (Music, Spotify).
    private func openAutomationSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private func openSystemSettings(_ address: String) {
        popover.performClose(nil)
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts a fresh copy through LaunchServices (so it is its own permission subject) and
    /// quits only once that launch has succeeded.
    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let logger = self.logger
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: - Audio lifecycle

    /// Keeps the icon in step with capture: every transition refreshes it, and while capture runs
    /// a slow timer re-checks for problems that arrive without a transition.
    private func captureStateChanged() {
        refreshStatus()
        if audioEngine.isCapturing {
            guard capturingStatusTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: capturingStatusRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
            timer.tolerance = capturingStatusRefreshInterval / 2
            capturingStatusTimer = timer
        } else {
            capturingStatusTimer?.invalidate()
            capturingStatusTimer = nil
        }
    }

    @objc private func displaysDidSleep() {
        isDisplayAsleep = true
        reconcileAudio()
    }

    @objc private func displaysDidWake() {
        isDisplayAsleep = false
        restartAttempts = 0
        reconcileAudio()
    }

    private func captureStoppedUnexpectedly(byUser: Bool, ranFor: TimeInterval) {
        if byUser {
            // Stopped from the system's capture indicator: respect that rather than restarting.
            logger.notice("Capture stopped from the system indicator; switching to Flow")
            settings.animationMode = .flow
            return
        }
        if ranFor >= healthyCaptureDuration {
            restartAttempts = 0
        }
        let delay = captureRestartDelays[min(restartAttempts, captureRestartDelays.count - 1)]
        restartAttempts += 1
        logger.notice("Retrying capture in \(delay, privacy: .public)s (attempt \(self.restartAttempts, privacy: .public))")
        refreshStatus()
        pendingRestart?.cancel()
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcileAudio()
        }
    }

    /// Makes capture, analysis and the per-display animation match the current state — on/off,
    /// visible displays, mode, permission and display sleep. Safe to call any number of times.
    private func reconcileAudio() {
        defer { refreshStatus() }
        let wantsMusic = settings.animationMode == .musicSync
            && !isDisplayAsleep
            && displayManager.hasVisibleOverlay
        guard wantsMusic else {
            stopAudioSync()
            return
        }
        guard audioEngine.checkPermission() == .granted else {
            if !loggedMissingPermission {
                loggedMissingPermission = true
                logger.error("Music Sync is on but Screen & System Audio Recording access isn't granted (preflight false); showing the steady glow")
            }
            stopAudioSync()
            return
        }
        loggedMissingPermission = false

        if !isSyncingAudio {
            isSyncingAudio = true
            beatDetector.start()
            let detector: BeatDetector = beatDetector
            displayManager.startAudioFrames { detector.snapshot() }
        } else if !audioEngine.isCapturing && !audioEngine.isStarting {
            // Capture is restarting under a running detector: give it a fresh session so its
            // "no audio yet" check and onset history describe the new stream.
            beatDetector.restartSession()
        }
        if !audioEngine.isCapturing && !audioEngine.isStarting {
            audioEngine.start()
        }
    }

    private func stopAudioSync() {
        pendingRestart?.cancel()
        pendingRestart = nil
        // A deliberate stop ends any failure episode: the next start gets a fresh retry schedule
        // (and `stop()` clears the failure the status would otherwise keep showing).
        restartAttempts = 0
        audioEngine.stop()
        guard isSyncingAudio else { return }
        isSyncingAudio = false
        displayManager.stopAudioFrames()
        beatDetector.stop()
    }
}
