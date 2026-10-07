<div align="center">

# Open Glow

**Ambient light for the edges of your Mac's screen — in the colors of what you're listening to, moving with the music.**

![Open Glow on a MacBook screen](docs/images/hero.png)

[Features](#features) · [Install](#install) · [Permissions](#permissions) · [Using it](#using-open-glow) · [Troubleshooting](#troubleshooting) · [How it works](#how-it-works)

</div>

---

Open Glow is a small, free, open-source menu-bar app for macOS. It lights the edges of your screen
like a soft bias light: the colors come from the album art of the song you're playing, flow slowly
around the screen, and swell with the music — big hits send light rushing along the edges, quiet
passages let it breathe.

It listens to your Mac's **audio output**, never the microphone.

## Features

- **Edge light** — light that pours in from the screen edges, brightest at the edge and fading
  smoothly inward, with soft corners and a proper wrap around the notch.
- **Album colors** — two colors taken from the now-playing track's artwork in Apple Music or
  Spotify, cross-fading on every track change. Black-and-white covers glow white; pastel covers
  stay soft.
- **Music Sync** — beats become smooth swells that travel along the edges: the bigger the hit, the
  bigger the swell. Optional stereo mode lets each side follow its own channel.
- **Flow** — with no music (or in Flow mode), the colors drift around the screen in soft blobs.
- **Coding-session glow** *(in progress)* — optionally, a sweep of Claude's warm orange when a
  Claude Code session starts, or Codex's colors when a Codex session starts.
- **Timers and Pomodoro** *(in progress)* — a ring of light that recedes around the screen as time
  runs out, with the countdown in the menu bar.
- **Your own colors** — a two-color gradient with a blend slider, or one of the presets.
- **Opening sweep** — light rises from the bottom of the screen and meets at the top whenever Open
  Glow starts.
- **Welcome tour** *(in progress)*, per-display toggles, launch at login, and every setting
  applies live.
- **Light on resources** — no dependencies, no private APIs; see [Performance](#performance).

## Screenshots

| Music Sync | Flow |
|---|---|
| ![Music Sync mid-swell](docs/images/hero.png) | ![Idle flow](docs/images/flow.png) |

| Opening sweep | Settings |
|---|---|
| ![Opening sweep](docs/images/opening-sweep.png) | <img src="docs/images/settings-dark.png" alt="Settings popover" width="260"> |

Different palettes — the soft default, a warm album, a cool album:

![Three palettes](docs/images/palettes.png)

## Requirements

- macOS 26 or later, Apple silicon
- To build: Swift 6 — Xcode, or just the Command Line Tools (`xcode-select --install`)

## Install

There are no prebuilt releases yet; building takes about a minute.

```bash
git clone https://github.com/Ayanprakash35/Open-glow.git
cd Open-glow
./Scripts/setup_signing.sh      # once — see "Signing" below
./Scripts/build_app.sh          # builds and signs build/Open Glow.app
open "build/Open Glow.app"
```

Copy `build/Open Glow.app` to `/Applications` if you like. Always start it through `open` (or
Finder), not by running the binary inside it — macOS then checks Open Glow's own permissions
rather than your terminal's.

### Signing

macOS remembers privacy permissions per app *identity*. An ad-hoc signature's identity is a hash of
the exact binary, so every rebuild would look like a new app and lose its permissions.
`Scripts/setup_signing.sh` creates a local, self-signed **"Open Glow Dev"** code-signing identity
once, in its own keychain (`~/Library/Keychains/openglow-signing.keychain-db`), and
`Scripts/build_app.sh` signs with it automatically, so permissions survive rebuilds. To remove it:

```bash
security delete-keychain ~/Library/Keychains/openglow-signing.keychain-db
rm -r ~/Library/Application\ Support/Open\ Glow\ Dev\ Signing
```

Without it, `build_app.sh` signs ad-hoc. You can also sign with any identity of your own:
`OPENGLOW_SIGN_IDENTITY="My Identity" ./Scripts/build_app.sh`.

### Running a build you downloaded

A copy downloaded from elsewhere is quarantined and won't carry a signature your Mac trusts.
Clear the quarantine flag and sign it ad-hoc:

```bash
xattr -dr com.apple.quarantine "Open Glow.app"
codesign --force --deep --sign - "Open Glow.app"
```

## Permissions

Open Glow asks for as little as it can, and only when a feature needs it. The welcome tour walks
through each one.

| Permission | Why | Where |
|---|---|---|
| **Screen & System Audio Recording** | Music Sync reads your Mac's audio output through ScreenCaptureKit, which macOS puts behind this permission. Open Glow never looks at the screen's contents. | System Settings › Privacy & Security › Screen & System Audio Recording |
| **Automation** (Music, Spotify) | Reads the current track and its artwork to color the glow. Open Glow never controls playback. macOS asks the first time a track plays. | System Settings › Privacy & Security › Automation |
| **Login Items** (optional) | Launch at login. | System Settings › General › Login Items |

There is no microphone permission — Open Glow never uses the microphone.

**Network:** Apple Music doesn't hand artwork to other apps for streamed tracks, so for those
Open Glow looks the cover up in Apple's public iTunes Search API, sending only the track's
artist, album and title. Nothing else leaves your Mac.

## Using Open Glow

Open Glow lives in the menu bar. **Click** the icon for settings; **right-click** (or
Control-click) for quick options and Quit.

### Animation

| Mode | What it does |
|---|---|
| **Music Sync** | Swells with whatever's playing; drifts gently when it's quiet. |
| **Flow** | Colors drift around the screen; audio is ignored and nothing is captured. |
| **Steady** | Holds still. |

**Reactivity** sets how big the swells get, **Flow speed** how fast the colors travel, and
**Stereo** lets the left and right edges follow their own channels. With the system's
**Reduce Motion** setting on, nothing travels or drifts; music still brightens the glow.

### Colors

- **Album Art** — from the track playing in Apple Music or Spotify (choose which in settings).
- **Gradient** — your own two colors and how much of the edge each covers.
- **Presets** — Mist, Dusk, Lagoon, Ember, Aurora, Citrus, Rose, Glacier.

### Glow

**Brightness**, **Thickness** (how far the light reaches inward) and **Softness** (how much of it
is a faint, wide bloom). Turn individual displays on or off, and choose whether the light curves
around the notch.

### Coding sessions *(in progress)*

Tick **Glow when a coding session starts** and Open Glow plays a short sweep in Claude's colors
when a Claude Code session starts, or Codex's colors for Codex — from the terminal or the Claude
app. It notices sessions by watching for their processes; nothing is sent anywhere.

## Troubleshooting

**Music Sync doesn't react.** Open the popover — it says what's wrong. If Screen & System Audio
Recording shows Open Glow enabled but nothing happens, macOS is holding a grant for an older build:

```bash
tccutil reset ScreenCapture com.openglow.app
```

then grant it again from the popover and relaunch. Running `Scripts/setup_signing.sh` once stops
this from happening after rebuilds.

**Colors don't change with the song.** Make sure Album Art is selected and the player is enabled in
settings. If you declined the Automation prompt: `tccutil reset AppleEvents com.openglow.app`,
then play a track and allow it. Streamed Apple Music tracks need a network connection for their
artwork. Black-and-white covers glow white on purpose.

**My Bluetooth headphones sound muffled.** That's the headphones' "headset" mode, which macOS
switches to when *some* app opens their microphone (check System Settings › Sound › Input).
Open Glow never opens the microphone.

**Nothing on the lock screen.** By design — macOS doesn't let apps draw there, and Open Glow
pauses completely while the screen is locked.

**Watching the logs.** In zsh, `log` is a built-in, so use the full path:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.openglow.app"'
```

## Tuning

Every number that shapes the look and feel is a named constant at the top of its file, with its
unit and a sensible range:

| Constants | File | Controls |
|---|---|---|
| `GlowMotionConfig` | `GlowMotion.swift` | Flow speed, swell rise and fall, beat weight, opening sweep, accent sweep |
| `EdgeLightConfig` | `EdgeLightRasterizer.swift` | Falloff shape, tail, resolution |
| `EdgeGeometryConfig` | `EdgeGeometry.swift` | Corner roundness |
| `GlowDefaults` | `GlowRenderer.swift` | Default brightness, thickness, softness |
| `EnvelopeConfig`, `FFTConfig` | `BeatDetector.swift` | Beat detection and grading, loudness tracking |
| `ColorExtractorConfig` | `ColorExtractor.swift` | How colors are picked from artwork |
| `ArtworkLookupConfig`, `AlbumArtConfig` | `ArtworkLookup.swift`, `ColorCoordinator.swift` | Artwork lookup and caching |

## How it works

- **Capture** — `AudioEngine` runs a ScreenCaptureKit stream with audio only (its video is a
  2×2-pixel stub at 1 fps, which ScreenCaptureKit requires) and writes 48 kHz stereo samples into
  a lock-protected ring buffer.
- **Analysis** — `BeatDetector` runs an FFT per 512-sample hop on its own queue: band energies
  with adaptive loudness normalization, and a SuperFlux-style onset detector on two bands (kick and
  full) that fires beats and grades each one by size.
- **Motion** — `GlowMotion` keeps the state of 480 points around the screen: colors from a slowly
  flowing field split between the palette's two colors, an idle drift of brighter and dimmer
  patches, and in Music Sync an envelope that turns beats into swells travelling outward along the
  edges.
- **Rendering** — `EdgeLightRasterizer` turns that state into four strip images (top, bottom,
  left, right) — light falling off smoothly from the edge — computed with integer math in the
  display's own color space; `GlowView` shows them as Core Animation layer contents, scaled up
  smoothly, in a click-through window above everything on each display.
- **Colors** — `NowPlayingMonitor` follows Music and Spotify through their notifications and
  AppleScript; `ArtworkLookup` finds covers for streamed tracks; `ColorExtractor` picks two colors
  with k-means in CIELAB.

```
Sources/OpenGlow/
  AppDelegate.swift             menu bar, popover, capture lifecycle
  Settings.swift                every preference, persisted
  SettingsView.swift            the popover
  DisplayManager.swift          one overlay window per display
  OverlayWindowController.swift the click-through overlay window
  GlowRenderer.swift            GlowView: layers and frame pacing
  GlowMotion.swift              what the light does from moment to moment
  EdgeLightRasterizer.swift     state → pixels
  EdgeGeometry.swift            distance from the edge, position around the screen
  AudioEngine.swift             system-audio capture
  AudioRingBuffer.swift         capture → analysis hand-off
  BeatDetector.swift            FFT, beats, loudness
  ColorCoordinator.swift        which palette to show
  NowPlaying*.swift             Music and Spotify
  ArtworkLookup.swift           covers for streamed tracks
  ColorExtractor.swift          artwork → palette
  GlowPalette.swift             colors and presets
  LaunchAtLogin.swift           SMAppService
```

## Performance

Measured on a MacBook Air (M-series, 15-inch) with one display:

| State | Open Glow CPU | Extra WindowServer CPU |
|---|---|---|
| Idle flow (30 fps) | 5–6% | — |
| Music Sync (60 fps) | 8–11% | 10–13% |

Phase 6 is bringing these down; see [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md) for how they're
measured and the full history in [docs/DEVLOG.md](docs/DEVLOG.md).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup, ground
rules (no dependencies, no private APIs, never the microphone) and code style.

## Acknowledgements

Inspired by ambient lighting — the soft bias light behind a TV, and ambient edge-lighting
visuals on the desktop. Open Glow is an independent project and isn't affiliated with any other
app.

## License

[MIT](LICENSE)
