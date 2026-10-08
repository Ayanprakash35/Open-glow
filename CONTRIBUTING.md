# Contributing to Open Glow

Thanks for wanting to help! Open Glow is a small, dependency-free macOS app, and a few rules
keep it that way.

## Setup

- macOS 26 or later on Apple silicon.
- Swift 6: Xcode, or just the Command Line Tools (`xcode-select --install`).

```bash
./Scripts/setup_signing.sh   # once: a local signing identity so macOS keeps permissions across rebuilds
./Scripts/build_app.sh       # builds and signs "build/Open Glow.app"
./Scripts/test.sh            # runs the test suite
```

`setup_signing.sh` is safe to run again; it repairs a half-finished setup. If the identity can't
be used, `build_app.sh` warns and signs ad-hoc rather than failing.

`Scripts/test.sh` wraps `swift test` with the flags Swift Testing needs when only the Command Line
Tools are installed; with Xcode, plain `swift test` works too.

Run the app through `open "build/Open Glow.app"` rather than the binary inside it, so macOS
checks Open Glow's own permissions instead of your terminal's.

## Ground rules

- **No third-party dependencies.** App code uses only Apple frameworks: Foundation, AppKit,
  SwiftUI, AVFoundation, ScreenCaptureKit, Accelerate, CoreImage and ServiceManagement (plus what
  they re-export).
- **No private APIs** and nothing that needs entitlements Apple doesn't give unsigned apps.
- **Never the microphone.** Music Sync reads the system's audio output through ScreenCaptureKit.
  No `AVAudioEngine.inputNode`, no `AVCaptureDevice` audio input, no `NSMicrophoneUsageDescription`.
- **Privacy:** the only network use is album art: a track's artist with its title (then album)
  and the region code, sent to Apple's public iTunes Search API for covers the player won't hand
  over, plus the cover downloads themselves (Apple's and Spotify's image servers). Players the
  user unticks are never contacted. Local data — the process list, coding tools' session logs —
  is read on the Mac and never logged or sent; only what's needed is read. Keep it that way, and
  update the README's Permissions section with any change.

## Code style

- Small files, one responsibility each.
- Tunable constants live in an enum at the top of their file, each with a doc comment giving the
  unit and a sensible range — people should be able to tweak the feel without reading the code.
- Comment what isn't obvious (AppKit and Core Animation incantations, the reason behind a
  number); skip comments that repeat the code.
- No force-unwraps except where failure is impossible.
- Swift 6 strict concurrency, zero warnings.

## Tests

Add or update tests with every change: Swift Testing, in `Tests/OpenGlowTests`. A few suites only
run when an environment variable is set, because they write images or use the network:

| Variable | What it does |
|---|---|
| `OPENGLOW_PREVIEW_DIR=<dir>` | Renders the edge light to PNGs (frames and a time-vs-position strip) |
| `OPENGLOW_SNAPSHOT_DIR=<dir>` | Renders the settings popover and welcome tour to PNGs |
| `OPENGLOW_NETWORK_TESTS=1` | Looks up real album art through the iTunes Search API |
| `OPENGLOW_LOOKUP="artist\|album\|title"` | Looks up one track's cover and prints what it found |
| `OPENGLOW_ACTIVITY_PROBE=1` | Prints how many Claude Code and Codex sessions on this Mac are mid-turn |
| `OPENGLOW_README_IMAGES=<dir>` | Regenerates the README's images |

For anything visible, also build the app and try it — the glow is easiest to judge by eye.

## App and menu-bar icons

`Scripts/make_icons.sh <logo.png> [<menu-bar-glyph.png>]` turns a square logo (ideally 1024 × 1024)
into `Resources/AppIcon.icns`, and an optional black-on-transparent glyph into
`Resources/MenuBarIcon.png` and `@2x`. `build_app.sh` bundles whichever of them exist; the app uses
the menu-bar glyph in place of its default symbol.

## Pull requests

Keep them focused, describe what you changed and how you tested it, and include before/after
images or a short screen recording for visual changes.
