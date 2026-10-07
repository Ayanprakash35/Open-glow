# Changelog

All notable changes to Open Glow. The full story, with dates and the problems solved along the
way, is in [docs/DEVLOG.md](docs/DEVLOG.md).

## Unreleased

### In progress
- Coding-session glow: a sweep in Claude's colors when a Claude Code session starts, or Codex's
  when a Codex session starts.
- Welcome tour window.
- Visual timers and Pomodoro: a ring of light that recedes around the screen, with the countdown in
  the menu bar.
- Lower CPU use; pausing on screen lock; recovery from audio-device changes and revoked
  permissions.

## 0.1.0 — 7 October 2026

First public version, renamed from Glowbar and released under the MIT license.

### Added
- Edge light: light that pours in from the screen edges with a smooth falloff, soft corners and a
  proper wrap around the notch, rendered on the CPU into four strips and composited by Core
  Animation in the display's color space.
- Music Sync: ScreenCaptureKit system-audio capture (never the microphone), FFT analysis,
  SuperFlux-style beat detection with graded beat sizes, and swells that travel along the edges.
- Flow and Steady animation modes, an idle drift of colors, and an opening sweep on launch.
- Album colors from Apple Music and Spotify, cross-faded on track changes; catalog lookup for
  streamed Apple Music tracks; white glow for black-and-white covers; soft glow for pastels.
- Settings popover: color source (album art, gradient, presets), brightness, thickness,
  softness, reactivity, flow speed, stereo, per-display toggles, notch handling, launch at login.
- A local signing identity so macOS permissions survive rebuilds; release builds by default.
- README, contributing guide, code of conduct, security policy, issue and PR templates, CI.
