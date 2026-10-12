# Changelog

All notable changes to Open Glow. The full story, with dates and the problems solved along the
way, is in [docs/DEVLOG.md](docs/DEVLOG.md).

## 0.1.1 — 12 October 2026

### Added
- **Timer on the main page**: a Timer section in the popover with a countdown menu, Custom…,
  Start Pomodoro, and Pause/Resume, Skip and Cancel while it runs.
- **Right-click menu options** for colors (source, presets, which players), coding sessions
  (per tool, with previews) and Launch at Login.
- **Per-tool coding-session switches** for Claude Code and Codex, in the popover, the menu and
  the welcome tour.
- `Scripts/make_icons.sh` and icon bundling, ready for a custom app and menu-bar icon.

### Changed
- The timer ring recedes smoothly at the timer's own pace instead of in once-a-second steps.
- While music plays, audio analysis no longer wakes the Mac on a timer (about 10 fewer wake-ups a
  second).
- Album colors: unticking Apple Music or Spotify takes effect at once and that player is never
  contacted again (no Apple Events, no Automation prompt, no downloads); your own Music files are
  no longer looked up online; lookups work in every region and pick the right album edition.
- Settings sliders rebuild the glow at most every 80 ms while dragged, so they no longer lag.
- The welcome tour shows the coding-session glow's real colors.
- Requires macOS 26 (now enforced by the app bundle).

### Fixed
- A crash with Stereo on when another app played audio containing invalid samples.
- The coding-session sweep lasting about 3× too long in Steady mode or with Reduce Motion.
- A faint dark line where the glow's strips meet.
- A display color-profile change leaving the glow costing extra CPU until another setting changed.
- A coding-session sweep cut off by locking the screen replaying after unlock.
- Sweep heads and timer pulses losing their width at low Reactivity.
- Claude Code installed with npm not being detected.
- "Skip to Break" also skipping the break when clicked just as a focus round ended; the long
  break's skip button now reads "Finish Pomodoro".
- Music Sync warnings hidden while a timer runs in the menu bar.
- "Grant Access…" doing nothing right after a grant that needs a relaunch; capture failures shown
  as permission problems; "Open Glow is off" shown when only the displays were unticked.
- `setup_signing.sh` reporting "Already set up" after a half-finished run; `build_app.sh` now
  falls back to ad-hoc signing instead of failing.

## 0.1.0 — 7 October 2026

First public release, renamed from Glowbar and published under the MIT license.

### Added
- **Edge light**: light that pours in from the screen edges with a smooth falloff, soft corners
  and a proper wrap around the notch, rendered on the CPU into four strips and handed to Core
  Animation as IOSurfaces in the display's own color space.
- **Music Sync**: ScreenCaptureKit system-audio capture (never the microphone), FFT analysis,
  SuperFlux-style beat detection with graded beat sizes, and swells that travel along the edges.
- **Flow** and **Steady** animation modes, an idle drift of colors, and an opening sweep on launch.
- **Album colors** from Apple Music and Spotify, cross-faded on track changes, with a catalog
  lookup for streamed Apple Music tracks; white glow for black-and-white covers, soft glow for
  pastels; choose which players to follow.
- **Coding-session glow**: a sweep in Claude's colors when a Claude Code session starts, or
  Codex's when a Codex session starts (optional).
- **Timers and Pomodoro**: a ring of light that recedes around the screen as time runs out, the
  countdown in place of the menu-bar icon, and soft pulses with a chime at each phase end.
- **Welcome tour**: permissions, music apps, look and motion, coding sessions, timers and launch
  at login, on first launch and from the menu.
- **Settings popover**: color source (album art, gradient, presets), brightness, thickness,
  softness, reactivity, flow speed, stereo, per-display toggles, notch handling, launch at login.
- Pauses completely while the screen is locked, the screen saver runs or another user is active;
  recovers by itself after audio-device changes, players quitting and permission changes.
- Preferences carried over from Glowbar.
- A local signing identity so macOS permissions survive rebuilds; optimized release builds.
- README, development log, measurements, contributing guide, code of conduct, security policy,
  issue and PR templates, CI.
