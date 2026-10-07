import SwiftUI

/// Layout of the welcome tour.
enum OnboardingLayout {
    /// The window's content size, in points.
    static let size = CGSize(width: 560, height: 470)
    /// Height of each page's illustration, in points. Sane range: 110–150.
    static let heroHeight: CGFloat = 128
    /// The first page has the fewest controls, so its illustration gets the room. Sane range: 128–180.
    static let welcomeHeroHeight: CGFloat = 156
    /// The last page has the most to say, so its illustration gives up some room. Sane range: 92–128.
    static let compactHeroHeight: CGFloat = 96
    /// Height of the bar with Skip, the page dots, Back and Continue, in points.
    static let navigationBarHeight: CGFloat = 58
    /// Widest the text and controls run, in points.
    static let contentWidth: CGFloat = 452
    /// Duration of the cross-fade between pages, in seconds. Sane range: 0.15–0.4.
    static let pageFade: Double = 0.25

    static func heroHeight(for page: OnboardingPage) -> CGFloat {
        switch page {
        case .welcome: welcomeHeroHeight
        case .allSet: compactHeroHeight
        default: heroHeight
        }
    }
}

/// What the tour's buttons do; `AppDelegate` supplies them.
struct OnboardingActions {
    /// Registers Open Glow for Screen & System Audio Recording and opens that settings pane.
    var grantScreenRecording: () -> Void
    var openAutomationSettings: () -> Void
    var setLaunchAtLogin: (Bool) -> Void
    /// The tour was finished or skipped.
    var finish: () -> Void
}

/// The tour's pages, in order.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, musicSync, albumColors, lookAndMotion, codingSessions, allSet

    var id: Int { rawValue }
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }
    var isLast: Bool { next == nil }

    /// Short name for the page indicator's accessibility value.
    var name: String {
        switch self {
        case .welcome: "Welcome"
        case .musicSync: "Music Sync"
        case .albumColors: "Album colors"
        case .lookAndMotion: "Look and motion"
        case .codingSessions: "Coding sessions"
        case .allSet: "All set"
        }
    }
}

/// The welcome tour: a few short pages explaining Open Glow, each with the setting it explains.
/// Every control writes straight into `Settings`, exactly like the popover, so changes show on
/// screen while the tour is still open.
struct OnboardingView: View {
    let settings: Settings
    let status: StatusModel
    let actions: OnboardingActions
    @State private var page: OnboardingPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(settings: Settings, status: StatusModel, actions: OnboardingActions, startPage: OnboardingPage = .welcome) {
        self.settings = settings
        self.status = status
        self.actions = actions
        _page = State(initialValue: startPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                OnboardingPageView(page: page, settings: settings, status: status, actions: actions)
                    .id(page)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            navigationBar
        }
        .frame(width: OnboardingLayout.size.width, height: OnboardingLayout.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 10) {
            if !page.isLast {
                Button("Skip Tour", action: actions.finish)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close the tour. You can open it again from Open Glow's menu.")
            }
            Spacer()
            if let previous = page.previous {
                Button("Back") { go(to: previous) }
                    .controlSize(.large)
            }
            Button(page.isLast ? "Done" : "Continue") {
                if let next = page.next {
                    go(to: next)
                } else {
                    actions.finish()
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .overlay { PageIndicator(page: page, select: go(to:)) }
        .padding(.horizontal, 20)
        .frame(height: OnboardingLayout.navigationBarHeight)
    }

    private func go(to target: OnboardingPage) {
        guard target != page else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: OnboardingLayout.pageFade)) {
            page = target
        }
    }
}

/// One dot per page, the current one drawn long; clicking a dot jumps to its page. VoiceOver
/// reads it as one adjustable element ("2 of 6, Music Sync").
private struct PageIndicator: View {
    let page: OnboardingPage
    let select: (OnboardingPage) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases) { candidate in
                Capsule()
                    .fill(candidate == page ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: candidate == page ? 18 : 7, height: 7)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { select(candidate) }
            }
        }
        .animation(.easeInOut(duration: OnboardingLayout.pageFade), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page")
        .accessibilityValue("\(page.rawValue + 1) of \(OnboardingPage.allCases.count), \(page.name)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: page.next.map(select)
            case .decrement: page.previous.map(select)
            @unknown default: break
            }
        }
    }
}
