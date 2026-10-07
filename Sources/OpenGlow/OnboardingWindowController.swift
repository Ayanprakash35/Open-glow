import AppKit
import SwiftUI

/// The welcome tour's window. Open Glow is a menu-bar app with no Dock icon, so `present()`
/// activates the app to bring the window in front of whatever the user is working in.
///
/// However the tour ends — Done, Skip Tour, Esc, ⌘W or the close button — the window closes and
/// `OnboardingActions.finish` runs exactly once.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private let status: StatusModel
    private let actions: OnboardingActions
    /// Set once `finish` has run for the current showing; `present()` after that starts over.
    private(set) var isFinished = false

    init(settings: Settings, status: StatusModel, actions: OnboardingActions) {
        self.settings = settings
        self.status = status
        self.actions = actions
        let window = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingLayout.size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to Open Glow"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // Showing again from the menu brings the window to the current Space instead of
        // switching to the one it was last on.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        super.init(window: window)
        window.delegate = self
        installTour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the tour in front of other apps, centered on the active screen. If it's already
    /// open it's only brought forward, keeping its page and position; after it finished, it
    /// starts again from the first page.
    func present() {
        guard let window else { return }
        if isFinished {
            isFinished = false
            installTour()
        }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // macOS may decline the activation if the user is busy in another app; the tour should
        // still show rather than open hidden behind it.
        window.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isFinished else { return }
        isFinished = true
        actions.finish()
    }

    // MARK: - Content

    private func installTour() {
        guard let window else { return }
        var tourActions = actions
        // Done and Skip close the window; closing reports `finish`, so every way out ends there.
        tourActions.finish = { [weak self] in self?.window?.performClose(nil) }
        let host = NSHostingController(rootView: OnboardingView(settings: settings, status: status, actions: tourActions))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: OnboardingLayout.size)
        window.contentViewController = host
        window.setContentSize(OnboardingLayout.size)
    }
}

/// Closes on Esc and ⌘W. An accessory app shows no menu bar, so nothing else would provide ⌘W.
private final class OnboardingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers
        if (modifiers.isEmpty && key == "\u{1b}") || (modifiers == .command && key == "w") {
            performClose(nil)
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}
