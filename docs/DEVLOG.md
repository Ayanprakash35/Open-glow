# Development log

How Open Glow came together, from the first prompt to today — what was built in each phase, what
went wrong, and how it was fixed. Dates are in IST. The app was called **Glowbar** until it was
renamed and open-sourced on 7 October 2026.

Hard numbers behind many of these entries are collected in [MEASUREMENTS.md](MEASUREMENTS.md).

---

## The brief — 11 August

A native macOS menu-bar app that draws an ambient glow around the edges of the screen and reacts to
whatever music is playing, built in six phases with a check-in after each:

1. Menu-bar skeleton and a static glow
2. Multiple displays and the notch
3. System-audio capture and beat detection
4. Colors from album art
5. Settings and persistence
6. Polish: performance, launch at login, edge cases, README

Ground rules from day one: macOS 26 on Apple silicon; Swift with SwiftUI where it fits and AppKit
where it doesn't; **no third-party dependencies** (Foundation, AppKit, SwiftUI, AVFoundation,
ScreenCaptureKit, Accelerate, CoreImage and ServiceManagement only); **never the microphone**; no
private frameworks; runnable unsigned on a personal Mac; small single-purpose files with every
tunable number documented at the top of its file.

**Toolchain.** No Xcode — just the Command Line Tools. The project became a Swift package plus a
script that assembles and signs the `.app` bundle. The first build failed to link
`PackageDescription`; a clean reinstall of the Command Line Tools fixed it.

---

## Phase 1 — a menu-bar app and a static glow · 11–12 August

- A status-bar item opening a SwiftUI popover, and one borderless, transparent, click-through
  overlay window per screen at the screen-saver level, on every Space, out of Mission Control and
  out of screenshots.
- The glow: Core Animation shapes and shadows rather than a SwiftUI blur, which is far too slow over
  a whole Retina screen.

**Problems and fixes**

- *The glow covered the whole screen in a pale wash.* A `CAShapeLayer` fills its `shadowPath` with
  the non-zero rule, so shadowing the ring's centerline lit the entire screen. The shadow path
  became the ring's stroked *outline*, and a containment mask now cuts the blur's long tail before
  it reaches the middle of the screen.
- *Pulsing the glow cost 4–5 ms per frame,* because a full-screen shadow was re-blurred every frame.
  The blurred halos became static and cached; only the crisp ring changed per frame.
- *Too thick.* The look was tuned by hand directly in the constants — a 16 pt ring with a 12 pt
  blur — which is exactly why every tunable lives in a documented constant.

Approved 12 August.

---

## Phase 2 — displays and the notch · 12 August

- Overlay windows are kept per display, keyed by the display's **UUID** rather than its index
  (indexes shuffle when displays come and go), rebuilt on every screen-configuration change, with
  per-display toggles that survive restarts and a pause on display sleep.
- `NSWindow(contentRect:…, screen:)` treats the rectangle as relative to that screen, so passing the
  screen's global frame placed windows on secondary displays far off-screen. Windows are now created
  at a zero origin and then moved with `setFrame(screen.frame)`.
- The notch is read from the screen's auxiliary top areas, with "curve around" and "ignore" modes.

Known gap at the time: the ring stopped at the notch instead of visibly wrapping it. Accepted to
keep moving; fixed for good by the edge-light renderer on 6 October.

---

## Phase 3 — system audio and beats · 12 August, 27–29 September

**Capture.** ScreenCaptureKit, with audio only — a ScreenCaptureKit stream must be tied to a
display, so its video is a 2×2-pixel, one-frame-per-second stub that's thrown away. Audio arrives
as 48 kHz deinterleaved float stereo and goes into a lock-protected ring buffer; any other format
is resampled to 48 kHz.

**"Music Sync isn't doing anything."** The first test with real music showed no reaction at all.
Three separate causes were found:

1. Reading a deinterleaved stereo sample buffer into a one-buffer `AudioBufferList` fails with
   −12737 (`kCMSampleBufferError_ArrayTooSmall`), so every buffer was silently dropped. The fix
   reads through `CMSampleBuffer.withAudioBufferList`.
2. With ad-hoc signing, the app's identity in macOS's privacy database is the hash of the exact
   binary, so **every rebuild** invalidated the Screen Recording permission — the privacy daemon's
   log said "Failed to match existing code requirement".
3. Starting the binary directly from a terminal made the *terminal* the subject of the permission
   check. The app is always started through `open` now.

Also discovered: `CGRequestScreenCaptureAccess` caches its answer for the life of the process, so
after calling it once the app could never see a grant made later in System Settings. The app never
calls it; it checks live with `CGPreflightScreenCaptureAccess` instead.

**Analysis.** A 2048-point FFT on every 512-sample hop, analysed exactly once however
ScreenCaptureKit happens to chunk its delivery; bass/mid/treble energies with per-band loudness
normalisation in dB; envelope followers (5 ms attack, 150 ms release); a gate with hysteresis; idle
after three seconds of silence.

Beat detection went through several designs. Plain spectral flux fired on fades, level changes and
sustained pads. The final design is a SuperFlux-style onset detector on log magnitudes — each bin's
rise over the previous frame's neighbouring bins, minus the median change across all bins, so
crescendos and level jumps cancel out — on two bands: a kick band and the full band, each with a
threshold of the median of the last second plus a fixed margin, and a 100 ms refractory period.

**A real-music test bench.** To tune against music rather than guesses, a harness built 45 test
tracks from Apple Loops — house, hip-hop, funk, dubstep, breaks, a live drummer, beatless pads,
hats-only material, full songs — where the isolated drum stem gives the true kick times. Final
numbers: **56% of kicks caught at full strength with 78% precision**, and about one false
full-strength flash every 12 seconds on beatless pads.

**Hardening.** Start and stop became synchronous state transitions (a quick stop-then-start used
to leave capture off), retries back off, a capture that delivers unreadable audio gets its own
warning, and the menu-bar icon always reflects the real state.

Confirmed working with real music on 29 September.

---

## Making it feel right · 29–30 September

First feedback with music playing: too flashy on the bass, boring at rest, no color variation from
song to song, every beat looking the same.

- **Graded beats.** Each beat's pulse is now sized by the hit — the onset's strength against a
  slowly adapting reference of recent hits, and how loud the low end is — while *which* moments
  count as beats stayed exactly the same (verified on all 45 tracks). Big kicks still burst
  (84% of real kicks now reach full size, up from 58%); hi-hat ticks became a subtle nudge (average
  size 0.28, down from 0.56); stray triggers on beatless pads mostly faded away (0.29, from 0.60).
- **Album colors.** A now-playing monitor follows Apple Music and Spotify through their own
  notifications and AppleScript, on a background queue, never relaunching a player that quit, and
  asking for the Automation permission only once something actually plays. A color extractor
  shrinks the cover to 64×64, clusters it with k-means in CIELAB and picks two glow-ready colors.
  An independent review caught that small neon accents on black covers were being thrown away as
  noise; they now count.
- **Settings.** One persisted settings store and a popover where every control applies live:
  colors (album art, a two-color gradient, presets), brightness, thickness, softness, reactivity,
  stereo, displays, notch, launch at login.

---

## A new renderer: the edge light · 6 October

Feedback on the result: the glow looked hard and cornery, beats went "thump thump", and it needed a
smooth, solid, flowing look with proper idle and music animations.

The target look was measured frame by frame from a reference screen recording rather than
eyeballed: brightness against distance from the edge, how fast colors travel around the screen,
and how quickly a swell rises and falls. Then the ring-and-shadow renderer was replaced entirely:

- **EdgeGeometry** gives every point near the border its distance from the edge — a smooth minimum
  over the sides, so corners bend instead of creasing — and its position around the screen,
  wrapping the notch properly at last.
- **GlowMotion** keeps 480 points around the screen: broad blobs of the palette's two colors
  sliding counter-clockwise, softly brighter and dimmer patches and a slow breath while idle, and in
  Music Sync an envelope (beats and bass, quick rise, slow fall) whose swells start at the middle of
  the top and bottom edges and travel outward.
- **EdgeLightRasterizer** turns that into light falling off smoothly from the edge — two
  exponentials, a main falloff and a faint wide tail — computed on a coarse grid in four strips
  along the edges and scaled up smoothly by Core Animation. No masks, shadows or offscreen passes.

The falloff ended up within a few percent of the target at every distance (see MEASUREMENTS.md).

**Performance surprises.**

- The real app used 11–15% CPU while idle, against a benchmark that predicted about 1%. Profiling
  showed Core Animation converting each frame from sRGB to the display's color space *on the CPU*.
  Frames are now drawn straight in the display's color space.
- The per-pixel loop ran about five times slower in the app than in the benchmark, because a light
  periodic load gets scheduled on the efficiency cores. It was rewritten as integer math — one
  table lookup and two multiplies per pixel for all four channels — taking a frame from 0.40 ms to
  0.15 ms.
- The build script had been producing **debug** builds the whole time. It builds optimized release
  builds by default now.

**Opening sweep.** On launch, light rises from the bottom center and races up both sides to meet at
the top, over a new default palette of soft icy blue and lavender.

---

## Album colors for streamed music · 6 October

- *No colors from Apple Music.* Music hands scripts no artwork for tracks streamed from Apple Music
  (confirmed by listening to Music's own broadcasts: no library file behind those tracks). For
  those, Open Glow looks the cover up in Apple's public iTunes Search API, sending the artist and
  title (then the album) with the Mac's region code. Searching by album turned out unreliable;
  searching by song finds the right track in both the Indian and US stores.
- *A black-and-white cover fell back to the default colors.* Covers with no color now glow white
  and silver in the cover's own tint; pastel covers stay soft (the saturation floor dropped from
  50% to 30%).
- *Colors seemed slow on some tracks.* The lookup now starts the moment a track starts, in parallel
  with asking Music (since 0.1.1, only for streamed tracks — a local file waits for Music's own
  artwork). Measured: new colors 170–470 ms after a track starts; a track heard before
  recolors instantly.

---

## Permissions that survive rebuilds · 6 October

A one-time script creates a self-signed "Open Glow Dev" code-signing identity in a keychain of its
own, and the build script signs with it. Along the way: `codesign` only accepts an untrusted
identity by its SHA-1 fingerprint and only from keychains on the search list, and an empty
`Resources` folder in the bundle failed strict signature verification. Result: the app's identity
is "this bundle ID, signed by this certificate", unchanged across rebuilds, so macOS keeps its
permissions.

**A detour:** muffled audio in Bluetooth headphones turned out to be the headphones' call mode
(1 channel at 16 kHz), which macOS switches to when some app opens their microphone. Quitting Open
Glow didn't change it, which ruled the app out.

---

## Open Glow · 7 October

- Renamed from Glowbar to **Open Glow** and released under the **MIT license**. The bundle ID
  changed to `com.openglow.app`; existing preferences are copied over once on first launch.
- Repository groundwork: README, contributing guide, code of conduct, security policy, issue and
  pull-request templates, and a CI workflow that builds and tests every push.
- Decided against drawing on the lock screen: macOS gives apps no public way to do it, and the
  project doesn't use private APIs. The glow pauses completely while the screen is locked.

Built the same day, each by a separate agent in its own copy of the project, then merged and wired
together:

- **Coding-session glow.** Each Claude Code session is its own `claude` process (from the terminal
  or the Claude app), and each Codex session a `codex` process, so Open Glow watches the process
  list every 1.5 s — about 0.04 ms a look — and plays a sweep in the tool's colors when a new one
  appears. Reading Claude Code's own entry point showed it also starts itself for jobs that aren't
  sessions (a browser bridge, built-in MCP servers, background workers, pre-started spares); those
  are filtered out so they don't trigger false sweeps.
- **Welcome tour.** Six pages — welcome, Music Sync permission, album colors and which players to
  follow, look and motion, coding sessions, and timers plus launch at login — with a small animated
  display whose edges glow. Its music animation first thumped on every beat; it now swells and
  glides like the real glow.
- **Timers and Pomodoro.** Time is measured on a monotonic clock that keeps counting through sleep
  (the uptime clock on this Mac had missed six days of sleep over eight days), so a timer left
  running with the lid closed is right when it opens. The whole edge starts lit and recedes
  clockwise from the top; the countdown replaces the menu-bar icon; each phase ends with three soft
  pulses and a chime.
- **Edge cases.** Lock screen, screen saver, fast user switching and sleep are tracked as separate
  reasons to pause — every one of the 90 orderings of lock, display sleep and system sleep ends in
  the right state. Capture recovers on its own after headphones or the output device change, a
  stream that delivers unreadable audio is replaced, and a revoked permission shows the warning
  instead of retrying forever.
- **CPU.** The renderer now computes only cells the light can currently reach and hands frames to
  Core Animation as IOSurfaces with no copy — 0.06 ms per frame, down from 0.15 ms, with frames
  pixel-for-pixel within a few levels of before. The beat detector now runs whenever audio arrives
  instead of on a 10.7 ms timer, uses a fast selection instead of sorting for its medians, and keeps
  its threshold history sorted: about 4× less CPU and about 10 timer wake-ups a second (a 100 ms
  watchdog) instead of 92, with bit-identical beats.

**First release, v0.1.0** — published on GitHub with a downloadable app.
