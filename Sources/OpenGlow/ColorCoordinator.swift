import AppKit
import os

/// Tuning for album-art colors.
enum AlbumArtConfig {
    /// Palettes remembered per track, so a recently played track recolors instantly without
    /// extracting again. Sane range: 8–128.
    static let paletteCacheSize = 32
}

/// What `ColorCoordinator` needs from a now-playing source: `NowPlayingMonitor` in the app, a
/// stand-in in tests.
@MainActor
protocol NowPlayingSource: AnyObject {
    var status: NowPlayingMonitor.Status { get }
    /// The players followed; any other is ignored entirely and never reported.
    var players: Set<NowPlayingMonitor.Player> { get set }
    var onStatusChange: ((NowPlayingMonitor.Status) -> Void)? { get set }
    var onArtwork: ((NowPlayingMonitor.Track, Data?) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

extension NowPlayingMonitor: NowPlayingSource {}

/// Decides the glow's palette — the user's gradient, a preset, or colors taken from the
/// now-playing track's artwork — and hands it to every display. Artwork colors cross-fade on each
/// track change; extraction runs off the main thread.
///
/// The players are watched only in Album Art mode, with the glow on, and only the ones the user
/// follows; with neither followed nothing is watched and the glow keeps the default colors.
/// Turning a player off drops its colors and cancels its lookup; turning it back on while it
/// plays colors the glow from the track it's playing.
///
/// Where a track's artwork comes from — and so what leaves the Mac:
/// - Apple Music, streamed (Music's notification names no file for it): Music gives scripts no
///   artwork for these, so the catalog lookup starts the moment the track starts, alongside
///   Music's own artwork query, and whichever answers first colors the glow — waiting for Music
///   to say "no artwork" first added a noticeable delay to every streamed track.
/// - Apple Music, a local file, or a track first seen through a script (at start, after Try
///   Again, or when Music is followed again), which may be either: Music's own artwork. The
///   catalog is asked only when Music hands over none.
/// - Spotify: the cover at the address Spotify reports, downloaded from Spotify's image CDN by
///   `NowPlayingMonitor`. The catalog is asked only when there's no usable cover (no address,
///   as for Spotify's local files, or the download failed).
///
/// The catalog lookup (`ArtworkLookup`) sends artist and title, then artist and album, with the
/// Mac's two-letter region code if it has one, to itunes.apple.com, and downloads the matching
/// cover from Apple's image server. It runs at most once per track while that track is current,
/// and never for a track whose colors are still among the last `paletteCacheSize`.
@MainActor
final class ColorCoordinator {
    typealias Player = NowPlayingMonitor.Player
    typealias Track = NowPlayingMonitor.Track
    /// Finds a track's cover by artist, album and title: `ArtworkLookup.artwork` in the app.
    typealias LookUpArtwork = @Sendable (_ artist: String, _ album: String, _ title: String) async -> Data?

    private let settings: Settings
    private let monitor: any NowPlayingSource
    private let lookUpArtwork: LookUpArtwork
    private let extractColors: @Sendable (Data) -> ColorExtractor.Result?
    /// Hands a palette to every display, cross-fading when asked to.
    private let showPalette: (GlowPalette, _ animated: Bool) -> Void
    private let logger = Logger(subsystem: "com.openglow.app", category: "Colors")
    private let extractionQueue = DispatchQueue(label: "com.openglow.colors.extraction", qos: .userInitiated)

    /// Latest palette from artwork; nil until a track with readable artwork has played, and again
    /// once the player it came from is no longer followed.
    private(set) var albumArtPalette: GlowPalette?
    /// Where that palette came from: vivid artwork, boosted muted artwork, black and white, or
    /// the fallback.
    private(set) var albumArtSource: ColorExtractor.Source?
    /// The player whose artwork that palette came from.
    private var albumArtPlayer: Player?
    private var cache: [String: ColorExtractor.Result] = [:]
    private var cacheOrder: [String] = []
    private var isMonitoring = false

    /// The track the glow should be showing, and its player; results for any other track are
    /// cached but not shown.
    private var current: (key: String, player: Player)?
    /// When `current` started, for the timing log.
    private var currentSince: TimeInterval = 0
    /// The catalog lookup for a track, kept after it finishes so the same track isn't looked up
    /// twice while it's current (the player saying "no artwork" after a lookup already ran).
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

    convenience init(settings: Settings, displayManager: DisplayManager) {
        self.init(settings: settings, monitor: NowPlayingMonitor(), showPalette: { palette, animated in
            displayManager.setPalette(palette, animated: animated)
        })
    }

    /// The defaults look artwork up in Apple's catalog and extract colors with `ColorExtractor`;
    /// tests replace them, and the monitor, with stand-ins.
    init(
        settings: Settings,
        monitor: any NowPlayingSource,
        lookUpArtwork: @escaping LookUpArtwork = { await ArtworkLookup.artwork(artist: $0, album: $1, title: $2) },
        extractColors: @escaping @Sendable (Data) -> ColorExtractor.Result? = { ColorExtractor.extract(fromImageData: $0) },
        showPalette: @escaping (GlowPalette, _ animated: Bool) -> Void
    ) {
        self.settings = settings
        self.monitor = monitor
        self.lookUpArtwork = lookUpArtwork
        self.extractColors = extractColors
        self.showPalette = showPalette
        monitor.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        monitor.onArtwork = { [weak self] track, artwork in self?.artworkArrived(for: track, artwork) }
    }

    /// Shows the palette for the current mode, and starts or stops watching the players: only
    /// Album Art mode, with the glow on and at least one player followed, has any reason to talk
    /// to Music or Spotify. Call it whenever any of those settings changes.
    func update(animated: Bool) {
        let followed = followedPlayers
        forgetUnfollowed(keeping: followed)
        let wantsMonitor = settings.colorMode == .albumArt && settings.isEnabled && !followed.isEmpty
        if isMonitoring, !wantsMonitor {
            isMonitoring = false
            monitor.stop()
            cancelLookup()
            current = nil
        }
        // While it runs, this drops or picks up players at once (see NowPlayingMonitor.players).
        monitor.players = followed
        if wantsMonitor, !isMonitoring {
            isMonitoring = true
            monitor.start()
        }
        showPalette(effectivePalette, animated)
        onChange?()
    }

    /// Asks the players again, e.g. after the user allows Automation access.
    func refreshNowPlaying() {
        monitor.refresh()
    }

    // MARK: - Players

    /// Whether album colors follow this player (both by default; the welcome tour and settings
    /// can turn either off).
    private func follows(_ player: Player) -> Bool {
        switch player {
        case .music: settings.followAppleMusic
        case .spotify: settings.followSpotify
        }
    }

    private var followedPlayers: Set<Player> {
        Set(Player.allCases.filter(follows))
    }

    /// Drops what a player the user just stopped following put on the glow: its track is no
    /// longer current (its catalog lookup is cancelled, so nothing it finds is shown), and its
    /// colors give way to the default. `update` then shows the effective palette.
    private func forgetUnfollowed(keeping followed: Set<Player>) {
        if let player = current?.player, !followed.contains(player) {
            cancelLookup()
            current = nil
        }
        if let player = albumArtPlayer, !followed.contains(player) {
            albumArtPalette = nil
            albumArtSource = nil
            albumArtPlayer = nil
        }
    }

    // MARK: - Tracks

    private func key(for track: Track) -> String {
        "\(track.player.rawValue):\(track.id)"
    }

    private func statusChanged(_ status: NowPlayingMonitor.Status) {
        if case .playing(let track) = status, !track.id.isEmpty, follows(track.player) {
            begin(track)
        }
        onChange?()
    }

    /// A track became current: show its colors at once if known; for a streamed Music track,
    /// start the catalog lookup without waiting for the player's own artwork query.
    private func begin(_ track: Track) {
        let key = key(for: track)
        guard key != current?.key else { return }
        current = (key, track.player)
        currentSince = ProcessInfo.processInfo.systemUptime
        if lookup?.key != key { cancelLookup() }
        if let cached = cache[key] {
            show(cached, for: key, via: "memory")
        } else if track.player == .music, track.isLocalFile == false {
            startLookup(for: track, key: key)
        }
    }

    private func artworkArrived(for track: Track, _ artwork: Data?) {
        guard follows(track.player) else { return }
        let key = key(for: track)
        if key != current?.key { begin(track) }
        if let cached = cache[key] {
            show(cached, for: key, via: "memory")
            return
        }
        if let artwork {
            // The player's own cover wins; the catalog lookup is no longer needed.
            if lookup?.key == key { cancelLookup() }
            extract(artwork, key: key, via: "player")
        } else if lookup?.key != key {
            // The player has none to give: a file without embedded art, a Spotify local file, a
            // failed download.
            startLookup(for: track, key: key)
        }
    }

    // MARK: - Artwork

    private func startLookup(for track: Track, key: String) {
        cancelLookup()
        guard !track.artist.isEmpty, !(track.title.isEmpty && track.album.isEmpty) else {
            logger.notice("Now-playing track has no artist or title to look its artwork up by; keeping the current colors")
            return
        }
        let (artist, album, title) = (track.artist, track.album, track.title)
        let lookUpArtwork = self.lookUpArtwork
        let task = Task { [weak self] in
            let cover = await lookUpArtwork(artist, album, title)
            // Cancelled when the track stopped being current or its player was turned off.
            guard let self, !Task.isCancelled else { return }
            guard let cover else {
                if self.current?.key == key, self.cache[key] == nil, !self.extracting.contains(key) {
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
        let extractColors = self.extractColors
        extractionQueue.async { [weak self] in
            let result = extractColors(artwork)
            Task { @MainActor in
                guard let self else { return }
                self.extracting.remove(key)
                guard let result else {
                    self.logger.error("Artwork couldn't be decoded (\(artwork.count, privacy: .public) bytes); keeping the current colors")
                    return
                }
                self.remember(result, for: key)
                self.show(result, for: key, via: source)
            }
        }
    }

    /// Shows `result` if it's for the current track and that track's player is still followed.
    private func show(_ result: ColorExtractor.Result, for key: String, via source: String) {
        guard let current, current.key == key, follows(current.player) else { return }
        albumArtPlayer = current.player
        guard result.palette != albumArtPalette || result.source != albumArtSource else { return }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - currentSince) * 1000)
        logger.notice("Colors from \(source, privacy: .public) artwork (\(String(describing: result.source), privacy: .public)) \(elapsed, privacy: .public) ms after the track started")
        albumArtPalette = result.palette
        albumArtSource = result.source
        if settings.colorMode == .albumArt {
            showPalette(result.palette, true)
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
