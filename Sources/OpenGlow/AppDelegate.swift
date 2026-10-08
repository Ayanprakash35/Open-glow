import AppKit
import SwiftUI
import os

/// How often the open popover refreshes its status, in seconds.
private let popoverRefreshInterval: TimeInterval = 0.5

/// How often Music Sync is re-checked while capture runs, in seconds. Catches what no event
/// announces — access revoked in System Settings, a capture display gone without a stream error —
/// and keeps the menu-bar icon current without the popover open. Each check is one privacy-service
/// preflight query. Sane range: 1–5.
private let capturingStatusRefreshInterval: TimeInterval = 2

/// Height of the app's own menu-bar logo (Resources/MenuBarIcon.png), in points. Menu-bar glyphs
/// are about 18 pt tall; Scripts/make_icons.sh makes the logo that size already, so this only
/// tames a logo dropped in at another size. Sane range: 16–22.
private let menuBarLogoHeight: CGFloat = 18

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
    private var sessionMonitor: ScreenSessionMonitor!
    private var codingSessionGlow: CodingSessionGlow!
    private var timers: TimerPresenter!
    /// The app's own logo for the everyday menu-bar icon, when the bundle has one; builds without
    /// it (`swift run` among them) show the SF Symbol.
    private lazy var menuBarLogo: NSImage? = Self.loadMenuBarLogo()
    /// Created the first time the tour opens and kept: its `finish` runs while its window closes.
    private var onboarding: OnboardingWindowController?
    private var onboardingRefreshTimer: Timer?

    private var isSyncingAudio = false
    private var loggedMissingPermission = false
    private var retry = CaptureRetry()
    private var pendingRestart: Task<Void, Never>?
    /// The next check for Screen Recording access while Music Sync waits for it.
    private var permissionWatch: Timer?
    private var permissionChecks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon, no app switcher entry. Set at runtime (rather than relying
        // solely on Info.plist LSUIElement) so this also holds true when launched via `swift run`
        // during development.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()

        // Everything `refreshStatus()` reads exists before anything below can trigger it.
        audioEngine = AudioEngine()
        beatDetector = BeatDetector(ringBuffer: audioEngine.ringBuffer)
        sessionMonitor = ScreenSessionMonitor()
        displayManager = DisplayManager()
        colorCoordinator = ColorCoordinator(settings: settings, displayManager: displayManager)
        codingSessionGlow = CodingSessionGlow(displayManager: displayManager)
        timers = TimerPresenter(displayManager: displayManager, statusItem: statusItem)
        // The popover shows the timer's section, so it comes after the presenter.
        setUpPopover()
        timers.onCountdownEnded = { [weak self] in self?.refreshStatus() }

        displayManager.applyBaseAppearanceToAll()
        displayManager.onDisplaysChanged = { [weak self] in self?.reconcileAudio() }
        colorCoordinator.onChange = { [weak self] in self?.refreshStatus() }
        colorCoordinator.update(animated: false)
        // Launched while locked or switched out: nothing shows, and no sweep plays, until that ends.
        displayManager.isSuspended = sessionMonitor.isPaused
        displayManager.playIntro()

        audioEngine.onUnexpectedStop = { [weak self] cause, ranFor in
            self?.captureStopped(cause, ranFor: ranFor)
        }
        audioEngine.onStartFailed = { [weak self] cause in
            self?.captureStopped(cause, ranFor: 0)
        }
        audioEngine.onStateChange = { [weak self] in self?.captureStateChanged() }
        sessionMonitor.onChange = { [weak self] old, new in self?.sessionChanged(from: old, to: new) }

        settings.onChange = { [weak self] change in self?.settingsChanged(change) }
        updateCodingSessionGlow()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )

        // The color panel is a window of this app, so a transient popover would close the moment
        // the user clicks into it. While it's up, the popover stays until closed explicitly.
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)

        reconcileAudio()

        if !settings.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    // MARK: - Status item and popover

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The button widens and narrows as a timer's countdown comes and goes, which a timer
        // started from the popover does while it's open.
        button.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(statusButtonResized), name: NSView.frameDidChangeNotification, object: button)
    }

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let actions = SettingsActions(
            grantScreenRecording: { [weak self] in self?.grantAccess() },
            openAutomationSettings: { [weak self] in self?.openAutomationSettings() },
            retryNowPlaying: { [weak self] in self?.colorCoordinator.refreshNowPlaying() },
            relaunch: { [weak self] in self?.relaunch() },
            setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
            openLoginItems: { LaunchAtLogin.openLoginItemsSettings() },
            quit: { NSApp.terminate(nil) },
            openTour: { [weak self] in self?.showOnboarding() }
        )
        // The Custom… length is asked in a modal alert. Closing the popover first keeps it from
        // sitting half-dismissed behind the alert; the right-click menu has its own actions.
        timers.panelModel.actions.askForCustomMinutes = { [weak self] in
            self?.popover.performClose(nil)
            return TimerMenu.promptForCustomMinutes()
        }
        let view = SettingsView(settings: settings, status: statusModel, timer: timers.panelModel, actions: actions)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    /// Keeps the popover's arrow on the button as the button changes width.
    @objc private func statusButtonResized() {
        // Optional: the button exists, and can be laid out, before the popover does.
        guard popover?.isShown == true, let button = statusItem.button else { return }
        popover.positioningRect = button.bounds
    }

    @objc private func statusItemClicked(_ sender: NSStatusItem?) {
        guard let event = NSApp.currentEvent else { return }
        // A click proves the screen is awake and unlocked, whatever notifications were missed.
        sessionMonitor.handle(.userInteracted)
        // Control-click is the secondary click for one-button mice and for people who turned
        // secondary click off; it must reach the menu (and Quit) too.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        // Opening the popover is the primary click, so it re-checks too — a grant made in
        // System Settings should take effect here, not only from the right-click menu.
        userAskedToRetry()
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
        // re-checks (as does a slow timer while access is missing). That works because
        // `checkPermission()` is a live query as long as the app never calls
        // CGRequestScreenCaptureAccess (see AudioEngine).
        userAskedToRetry()

        let state = StatusMenu.State(
            displays: displayManager.displays,
            musicSync: musicSyncStatus(),
            glowVisible: displayManager.hasVisibleOverlay,
            launchAtLogin: LaunchAtLogin.state
        )
        let menu = StatusMenu.make(settings: settings, state: state, timerItem: timers.menuItem(), actions: menuActions())

        // Pop the menu at the button's location directly, rather than assigning it to
        // statusItem.menu, so left-click keeps opening the popover instead of this menu.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menuActions() -> StatusMenu.Actions {
        StatusMenu.Actions(
            openSettings: { [weak self] in self?.showPopover() },
            grantScreenRecording: { [weak self] in self?.grantAccess() },
            relaunch: { [weak self] in self?.relaunch() },
            previewCodingSession: { [weak self] tool in self?.displayManager.playAccent(tool.palette) },
            setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLoginFromMenu(enabled) },
            openLoginItems: { LaunchAtLogin.openLoginItemsSettings() },
            openTour: { [weak self] in self?.showOnboarding() },
            quit: { NSApp.terminate(nil) }
        )
    }

    // MARK: - Settings

    /// Applies a setting the moment it changes — from the popover (including mid-drag) or the menu.
    private func settingsChanged(_ change: Settings.Change) {
        switch change {
        case .enabled:
            displayManager.applyVisibility()
            colorCoordinator.update(animated: false)
            if settings.isEnabled { displayManager.playIntro() }
            updateCodingSessionGlow()
            reconcileAudio()
        case .animationMode:
            retry.reset()
            displayManager.applyBaseAppearanceToAll()
            reconcileAudio()
        case .displays:
            displayManager.applyVisibility()
            reconcileAudio()
        case .notchMode:
            displayManager.refreshNotchMode()
        case .players:
            colorCoordinator.update(animated: true)
        case .codingSessionGlow:
            updateCodingSessionGlow()
        case .onboarding:
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

    /// Watches for coding sessions only while one could glow: the option on, at least one tool
    /// chosen, and Open Glow on. With no tool chosen the process table isn't read at all.
    private func updateCodingSessionGlow() {
        let anyTool = CodingSessionMonitor.Tool.allCases.contains { settings.glowsForCodingSession($0) }
        codingSessionGlow.update(enabled: anyTool && settings.isEnabled)
    }

    // MARK: - Welcome tour

    /// Opens the welcome tour — by itself on first launch, and from the menu or the popover.
    private func showOnboarding() {
        popover.performClose(nil)
        userAskedToRetry()
        statusModel.launchAtLoginError = nil
        refreshStatus(includingPopoverDetails: true)
        if onboarding == nil {
            onboarding = OnboardingWindowController(settings: settings, status: statusModel, actions: OnboardingActions(
                grantScreenRecording: { [weak self] in self?.grantAccess() },
                openAutomationSettings: { [weak self] in self?.openAutomationSettings() },
                setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
                finish: { [weak self] in self?.onboardingFinished() }
            ))
        }
        onboarding?.present()
        // Permission and launch-at-login changes made in System Settings show up live in the tour.
        onboardingRefreshTimer?.invalidate()
        onboardingRefreshTimer = Timer.scheduledTimer(withTimeInterval: popoverRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    private func onboardingFinished() {
        settings.hasCompletedOnboarding = true
        onboardingRefreshTimer?.invalidate()
        onboardingRefreshTimer = nil
        refreshStatus()
    }

    private var isShowingOnboarding: Bool {
        onboarding?.window?.isVisible == true
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        statusModel.launchAtLoginError = LaunchAtLogin.setEnabled(enabled)
        refreshStatus()
    }

    /// The popover and the tour show a failure under their toggle; the menu has closed by now,
    /// so a failure from it gets an alert instead of passing unseen.
    private func setLaunchAtLoginFromMenu(_ enabled: Bool) {
        setLaunchAtLogin(enabled)
        guard let error = statusModel.launchAtLoginError else { return }
        let alert = NSAlert()
        alert.messageText = enabled ? "Open Glow couldn't turn on Launch at Login" : "Open Glow couldn't turn off Launch at Login"
        alert.informativeText = error
        // A menu-bar app isn't frontmost; without this the alert opens behind other windows.
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Status

    private func musicSyncStatus() -> MusicSyncStatus {
        let capture: MusicSyncStatus.Capture = audioEngine.isCapturing
            ? .running(audioEngine.captureHealth)
            : .notRunning(lastFailure: audioEngine.lastFailure)
        return .resolve(
            overlayVisible: displayManager.hasVisibleOverlay,
            musicSyncSelected: settings.animationMode == .musicSync,
            permission: audioEngine.permissionState,
            capture: capture,
            reportsFailure: retry.reportsFailure,
            analysis: beatDetector.snapshot()
        )
    }

    /// Updates the status icon and the popover's live state. The popover's details are only
    /// gathered while it's open (or about to open) — nobody sees them otherwise.
    private func refreshStatus(includingPopoverDetails: Bool = false) {
        let status = musicSyncStatus()
        statusModel.musicSync = status
        if includingPopoverDetails || popover.isShown || isShowingOnboarding {
            statusModel.nowPlaying = colorCoordinator.nowPlaying
            statusModel.palette = colorCoordinator.effectivePalette
            statusModel.albumArtSource = colorCoordinator.albumArtSource
            statusModel.launchAtLogin = LaunchAtLogin.state
            statusModel.displays = displayManager.displays
            statusModel.systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        let icon = StatusIcon(status: status, glowEnabled: settings.isEnabled)
        // While a timer runs, its countdown takes the icon's place, so a warning has to travel
        // with the countdown or nothing in the menu bar would show it.
        timers.attention = icon.timerAttention
        guard let button = statusItem.button, !timers.isRunning else { return }
        button.image = image(for: icon)
        button.appearsDisabled = icon.appearsDisabled
        button.toolTip = icon.description
    }

    /// The logo for the everyday icon when the bundle has one; the SF Symbol otherwise, and for
    /// the off and warning states, which have to read differently.
    private func image(for icon: StatusIcon) -> NSImage? {
        if icon.isNormal, let logo = menuBarLogo {
            logo.accessibilityDescription = icon.description
            return logo
        }
        return NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.description)
    }

    private static func loadMenuBarLogo() -> NSImage? {
        guard let logo = Bundle.main.image(forResource: "MenuBarIcon"), logo.size.height > 0 else { return nil }
        // A template image: macOS tints it for light and dark menu bars, and dims it like a symbol.
        logo.isTemplate = true
        if logo.size.height != menuBarLogoHeight {
            logo.size = NSSize(width: logo.size.width * menuBarLogoHeight / logo.size.height, height: menuBarLogoHeight)
        }
        return logo
    }

    // MARK: - Permission actions

    /// Registers Open Glow with the privacy system (which may show macOS's own prompt) and opens
    /// the Screen & System Audio Recording pane, so the click always leads somewhere visible —
    /// if access was already denied, macOS won't prompt again and the pane is the only way on.
    private func grantAccess() {
        popover.performClose(nil)
        Task {
            await audioEngine.registerForScreenRecording()
            // Read before the retry below: it clears ScreenCaptureKit's refusal, after which the
            // state where macOS's preflight says yes but capture is refused (a grant made while
            // Open Glow runs) reads as granted, and the click would lead nowhere.
            let accessMissing = audioEngine.permissionState != .granted
            userAskedToRetry()
            if accessMissing {
                openPrivacySettings()
            }
        }
    }

    private func openPrivacySettings() {
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
    private func relaunch() {
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
    /// a slow timer re-checks for problems that arrive without a transition — access revoked in
    /// System Settings (a stream doesn't always stop when it is) among them.
    private func captureStateChanged() {
        refreshStatus()
        if audioEngine.isCapturing {
            guard capturingStatusTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: capturingStatusRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAudio() }
            }
            timer.tolerance = capturingStatusRefreshInterval / 2
            capturingStatusTimer = timer
        } else {
            capturingStatusTimer?.invalidate()
            capturingStatusTimer = nil
        }
    }

    /// Sleep, the lock screen, the screen saver or user switching began or ended: overlays hide
    /// and capture stops while any holds, and everything comes back as it was — no opening sweep —
    /// once none does.
    private func sessionChanged(from old: SessionPauseReasons, to new: SessionPauseReasons) {
        displayManager.isSuspended = !new.isEmpty
        if !old.isEmpty, new.isEmpty {
            // Whatever failed before the pause gets a fresh retry schedule.
            retry.reset()
        }
        reconcileAudio()
    }

    /// The user is looking at Music Sync's state (menu, popover, Grant Access): anything held back
    /// until they act gets one more try, and access checks start quick again.
    private func userAskedToRetry() {
        audioEngine.allowRetryAfterRefusal()
        stopPermissionWatch()
        // Someone looking at a failure shouldn't wait out the rest of the backoff.
        pendingRestart?.cancel()
        pendingRestart = nil
        reconcileAudio()
    }

    private func captureStopped(_ cause: CaptureStopCause, ranFor: TimeInterval) {
        switch cause {
        case .userStopped:
            // Stopped from the system's capture indicator: respect that rather than restarting.
            logger.notice("Capture stopped from the system indicator; switching to Flow")
            settings.animationMode = .flow
            return
        case .accessDenied:
            // The engine now treats access as missing: reconciling shows the warning and watches
            // for a grant instead of retrying.
            reconcileAudio()
            return
        case .failed, .unreadable:
            // Access revoked in System Settings doesn't always surface as a refusal; the live
            // check tells, and retrying without access would only fail again.
            guard audioEngine.checkPermission() == .granted else {
                reconcileAudio()
                return
            }
        }
        let delay = retry.next(afterRunningFor: ranFor)
        logger.notice("Retrying capture in \(delay, privacy: .public)s (attempt \(self.retry.attempts, privacy: .public))")
        pendingRestart?.cancel()
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pendingRestart = nil
            self?.reconcileAudio()
        }
        refreshStatus()
    }

    /// Makes capture, analysis and the per-display animation match the current state — on/off,
    /// visible displays, mode, permission, sleep and lock, and the display capture is tied to.
    /// Safe to call any number of times.
    private func reconcileAudio() {
        defer { refreshStatus() }
        let decision = MusicSyncPlan.decide(
            musicSyncSelected: settings.animationMode == .musicSync,
            overlayVisible: displayManager.hasVisibleOverlay,
            paused: sessionMonitor.isPaused,
            permission: audioEngine.checkPermission(),
            engine: engineState()
        )
        switch decision {
        case .off:
            stopPermissionWatch()
            stopAudioSync()
        case .awaitingPermission:
            if !loggedMissingPermission {
                loggedMissingPermission = true
                logger.error("Music Sync is on but Screen & System Audio Recording access isn't granted; showing the idle flow")
            }
            stopAudioSync()
            watchPermission()
        case .run(let step):
            stopPermissionWatch()
            loggedMissingPermission = false
            runAudioSync(step)
        }
    }

    private func engineState() -> MusicSyncPlan.Engine {
        if audioEngine.isStarting { return .starting }
        guard audioEngine.isCapturing else { return pendingRestart == nil ? .idle : .waitingToRetry }
        let onConnectedDisplay = audioEngine.captureDisplayID.map(DisplayManager.isOnline) ?? true
        return .running(onConnectedDisplay: onConnectedDisplay)
    }

    private func runAudioSync(_ step: MusicSyncPlan.Step) {
        let detectorWasRunning = isSyncingAudio
        if !isSyncingAudio {
            isSyncingAudio = true
            beatDetector.start()
            let detector: BeatDetector = beatDetector
            displayManager.startAudioFrames { detector.snapshot() }
        }
        switch step {
        case .keep:
            break
        case .start:
            // Capture is restarting under a running detector: give it a fresh session so its
            // "no audio yet" check and onset history describe the new stream.
            if detectorWasRunning { beatDetector.restartSession() }
            audioEngine.start()
        case .restart:
            logger.notice("The display audio capture was attached to is gone; restarting capture")
            audioEngine.stop()
            beatDetector.restartSession()
            audioEngine.start()
        }
    }

    private func stopAudioSync() {
        pendingRestart?.cancel()
        pendingRestart = nil
        // A deliberate stop ends any failure episode: the next start gets a fresh retry schedule
        // (and `stop()` clears the failure the status would otherwise keep showing).
        retry.reset()
        audioEngine.stop()
        guard isSyncingAudio else { return }
        isSyncingAudio = false
        displayManager.stopAudioFrames()
        beatDetector.stop()
    }

    /// Re-checks access after a delay that grows from quick (just after the user acted, or right
    /// after access went missing) to slow.
    private func watchPermission() {
        guard permissionWatch == nil else { return }
        let delay = CaptureRetryConfig.delay(CaptureRetryConfig.permissionCheckDelays, attempt: permissionChecks)
        permissionChecks += 1
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.permissionWatch = nil
                self?.reconcileAudio()
            }
        }
        timer.tolerance = delay / 4
        permissionWatch = timer
    }

    private func stopPermissionWatch() {
        permissionWatch?.invalidate()
        permissionWatch = nil
        permissionChecks = 0
    }
}
