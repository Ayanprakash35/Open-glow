import AppKit
import os

/// Tuning for album-art colors.
enum AlbumArtConfig {
    /// Palettes remembered per track, so a recently played track recolors instantly without
    /// extracting again. Sane range: 8–128.
    static let paletteCacheSize = 32
}

/// Decides the glow's palette — the user's gradient, a preset, or colors taken from the
/// now-playing track's artwork — and hands it to every display. Artwork colors cross-fade on each
/// track change; extraction runs off the main thread.
///
/// Artwork comes from the player when it provides it, and otherwise from Apple's catalog
/// (`ArtworkLookup`): Music gives scripts nothing for streamed Apple Music tracks. For Music the
/// catalog lookup starts the moment a track starts, alongside the player's own artwork query,
/// and whichever answers first colors the glow — waiting for Music to say "no artwork" first
/// added a noticeable delay to every streamed track.
@MainActor
final class ColorCoordinator {
    private let settings: Settings
    private let displayManager: DisplayManager
    private let monitor = NowPlayingMonitor()
    private let logger = Logger(subsystem: "com.openglow.app", category: "Colors")
    private let extractionQueue = DispatchQueue(label: "com.openglow.colors.extraction", qos: .userInitiated)

    /// Latest palette from artwork; nil until a track with readable artwork has played.
    private(set) var albumArtPalette: GlowPalette?
    /// Where that palette came from: vivid artwork, boosted muted artwork, black and white, or
    /// the fallback.
    private(set) var albumArtSource: ColorExtractor.Source?
    private var cache: [String: ColorExtractor.Result] = [:]
    private var cacheOrder: [String] = []
    private var isMonitoring = false

    /// The track the glow should be showing; results for any other track are cached but not shown.
    private var currentKey: String?
    /// When `currentKey` started, for the timing log.
    private var currentSince: TimeInterval = 0
    private var lookup: (key: String, task: Task<Void, Never>)?
    /// Tracks whose artwork is being extracted, so the player's and the catalog's copies of the
    /// same cover aren't both processed.
    private var extracting: Set<String> = []

    /// Called when the now-playing state or the palette changes, so the popover can refresh.
    var onChange: (() -> Void)?

    var nowPlaying: NowPlayingMonitor.Status { monitor.status }

    /// The palette the current color mode calls for.
    var effectivePalette: GlowPalette {
        settings.colorMode == .albumArt ? (albumArtPalette ?? .fallback) : settings.chosenPalette
    }

    init(settings: Settings, displayManager: DisplayManager) {
        self.settings = settings
        self.displayManager = displayManager
        monitor.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        monitor.onArtwork = { [weak self] track, artwork in self?.artworkArrived(for: track, artwork) }
    }

    /// Shows the palette for the current mode and starts or stops watching the players: only
    /// Album Art mode, with the glow on, has any reason to talk to Music or Spotify.
    func update(animated: Bool) {
        let wantsMonitor = settings.colorMode == .albumArt && settings.isEnabled
        if wantsMonitor != isMonitoring {
            isMonitoring = wantsMonitor
            if wantsMonitor {
                monitor.start()
            } else {
                monitor.stop()
                cancelLookup()
                currentKey = nil
            }
        }
        displayManager.setPalette(effectivePalette, animated: animated)
        onChange?()
    }

    /// Asks the players again, e.g. after the user allows Automation access.
    func refreshNowPlaying() {
        monitor.refresh()
    }

    // MARK: - Tracks

    private func key(for track: NowPlayingMonitor.Track) -> String {
        "\(track.player.rawValue):\(track.id)"
    }

    /// Whether album colors follow this player (both by default; the welcome tour and settings
    /// can turn either off).
    private func follows(_ player: NowPlayingMonitor.Player) -> Bool {
        switch player {
        case .music: settings.followAppleMusic
        case .spotify: settings.followSpotify
        }
    }

    private func statusChanged(_ status: NowPlayingMonitor.Status) {
        if case .playing(let track) = status, !track.id.isEmpty, follows(track.player) {
            begin(track)
        }
        onChange?()
    }

    /// A track became current: show its colors at once if known; for Music, start the catalog
    /// lookup without waiting for the player's own artwork query.
    private func begin(_ track: NowPlayingMonitor.Track) {
        let key = key(for: track)
        guard key != currentKey else { return }
        currentKey = key
        currentSince = ProcessInfo.processInfo.systemUptime
        if lookup?.key != key { cancelLookup() }
        if let cached = cache[key] {
            show(cached, for: key, via: "memory")
        } else if track.player == .music {
            startLookup(for: track, key: key)
        }
    }

    private func artworkArrived(for track: NowPlayingMonitor.Track, _ artwork: Data?) {
        guard follows(track.player) else { return }
        let key = key(for: track)
        if key != currentKey { begin(track) }
        if let cached = cache[key] {
            show(cached, for: key, via: "memory")
            return
        }
        if let artwork {
            // The player's own cover wins; the catalog lookup is no longer needed.
            if lookup?.key == key { cancelLookup() }
            extract(artwork, key: key, via: "player")
        } else if lookup?.key != key {
            startLookup(for: track, key: key)
        }
    }

    // MARK: - Artwork

    private func startLookup(for track: NowPlayingMonitor.Track, key: String) {
        cancelLookup()
        guard !track.artist.isEmpty, !(track.title.isEmpty && track.album.isEmpty) else {
            logger.notice("Now-playing track has no artist or title to look its artwork up by; keeping the current colors")
            return
        }
        let (artist, album, title) = (track.artist, track.album, track.title)
        let task = Task { [weak self] in
            let cover = await ArtworkLookup.artwork(artist: artist, album: album, title: title)
            guard let self, !Task.isCancelled else { return }
            if self.lookup?.key == key { self.lookup = nil }
            guard let cover else {
                if self.currentKey == key, self.cache[key] == nil, !self.extracting.contains(key) {
                    // Radio, some podcasts, nothing matching: keep the current colors rather than
                    // flashing to a default between tracks that have art.
                    self.logger.notice("No artwork for the now-playing track; keeping the current colors")
                }
                return
            }
            self.extract(cover, key: key, via: "catalog")
        }
        lookup = (key, task)
    }

    private func cancelLookup() {
        lookup?.task.cancel()
        lookup = nil
    }

    private func extract(_ artwork: Data, key: String, via source: String) {
        guard cache[key] == nil, !extracting.contains(key) else { return }
        extracting.insert(key)
        extractionQueue.async { [weak self] in
            let result = ColorExtractor.extract(fromImageData: artwork)
            Task { @MainActor in
                guard let self else { return }
                self.extracting.remove(key)
                guard let result else {
                    self.logger.error("Artwork couldn't be decoded (\(artwork.count, privacy: .public) bytes); keeping the current colors")
                    return
                }
                self.remember(result, for: key)
                if key == self.currentKey {
                    self.show(result, for: key, via: source)
                }
            }
        }
    }

    private func show(_ result: ColorExtractor.Result, for key: String, via source: String) {
        guard key == currentKey, result.palette != albumArtPalette || result.source != albumArtSource else { return }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - currentSince) * 1000)
        logger.notice("Colors from \(source, privacy: .public) artwork (\(String(describing: result.source), privacy: .public)) \(elapsed, privacy: .public) ms after the track started")
        albumArtPalette = result.palette
        albumArtSource = result.source
        if settings.colorMode == .albumArt {
            displayManager.setPalette(result.palette, animated: true)
        }
        onChange?()
    }

    private func remember(_ result: ColorExtractor.Result, for key: String) {
        if cache.updateValue(result, forKey: key) == nil {
            cacheOrder.append(key)
        }
        while cacheOrder.count > AlbumArtConfig.paletteCacheSize {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
