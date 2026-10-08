import SwiftUI

/// What the popover's Timer section shows and does. `TimerPresenter` sets `snapshot` on every
/// tick and change; the buttons go through `actions`, which drive its `TimerController`.
@MainActor
@Observable
final class TimerPanelModel {
    /// The running timer as of its latest tick or change; nil when no timer runs.
    var snapshot: TimerSnapshot?
    /// The Pomodoro that Start Pomodoro begins, and whose lengths its title shows.
    var plan: PomodoroPlan
    /// What the buttons call. The owner may swap in its own, for example to close the popover
    /// before the Custom… alert opens.
    @ObservationIgnored var actions: TimerMenu.Actions

    init(plan: PomodoroPlan = .standard, actions: TimerMenu.Actions) {
        self.plan = plan
        self.actions = actions
    }

    /// Countdown lengths on offer, in minutes.
    var presetMinutes: [Int] { TimerMenuConfig.presetMinutes }

    /// "Start Pomodoro (25/5)".
    var pomodoroTitle: String { TimerMenu.pomodoroTitle(for: plan) }

    func startCountdown(minutes: Int) { actions.startCountdown(minutes: minutes) }

    /// Asks for a length and starts it; does nothing if the user cancels.
    func startCustomCountdown() { actions.startCustomCountdown() }

    func startPomodoro() { actions.startPomodoro(plan) }
    func pause() { actions.pause() }
    func resume() { actions.resume() }

    /// Skips the phase `shown` describes: the one on screen when the user clicked. If it ran out
    /// before the view caught up, nothing is skipped, rather than the phase that followed it.
    func skipPhase(shown: TimerSnapshot) { actions.skipPhase(shown.kind, shown.round) }

    func cancel() { actions.cancel() }
}

/// The body of the popover's Timer section: a countdown menu and Start Pomodoro when idle; the
/// phase, the time left and its controls while a timer runs. Made to sit under the popover's
/// section title and take its small control size.
struct TimerPanel: View {
    let model: TimerPanelModel

    var body: some View {
        if let snapshot = model.snapshot {
            running(snapshot)
        } else {
            idle
        }
    }

    private var idle: some View {
        HStack(spacing: 8) {
            Menu("Countdown") {
                ForEach(model.presetMinutes, id: \.self) { minutes in
                    Button(TimerMenu.presetTitle(minutes: minutes)) { model.startCountdown(minutes: minutes) }
                }
                Divider()
                Button("Custom…", action: model.startCustomCountdown)
            }
            // A menu otherwise stretches to fill the row.
            .fixedSize()
            Button(model.pomodoroTitle, action: model.startPomodoro)
            Spacer(minLength: 0)
        }
    }

    private func running(_ snapshot: TimerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: TimerMenu.statusSymbol(for: snapshot))
                    .foregroundStyle(.secondary)
                    // The glyphs differ in width; a fixed slot keeps the phase name from shifting
                    // when the timer pauses or a break starts.
                    .frame(width: 14)
                Text(TimerMenu.phaseName(for: snapshot))
                if snapshot.isPaused {
                    Text("Paused").foregroundStyle(.secondary)
                }
                Spacer()
                Text(TimerMenu.clockString(seconds: snapshot.displaySeconds))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            .font(.caption)
            // One element for VoiceOver, read as "Focus 2 of 4 — 24:13 left".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TimerMenu.headerTitle(for: snapshot))
            // Drains as the ring of light around the screens does; the clock above says the same
            // for VoiceOver.
            ProgressView(value: snapshot.remainingFraction)
                .accessibilityHidden(true)
            HStack {
                if snapshot.isPaused {
                    Button("Resume", action: model.resume)
                } else {
                    Button("Pause", action: model.pause)
                }
                if let skipTitle = TimerMenu.skipTitle(for: snapshot) {
                    Button(skipTitle) { model.skipPhase(shown: snapshot) }
                }
                Spacer()
                Button("Cancel Timer", action: model.cancel)
            }
        }
    }
}
