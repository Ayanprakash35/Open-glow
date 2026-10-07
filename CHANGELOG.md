# Changelog

All notable changes to Open Glow. The full story, with dates and the problems solved along the
way, is in [docs/DEVLOG.md](docs/DEVLOG.md).

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
