import Foundation
import Testing
@testable import OpenGlow

private typealias Player = NowPlayingMonitor.Player
private typealias Track = NowPlayingMonitor.Track

// Nothing here talks to Music or Spotify or the network: the monitor's Apple Events, the catalog
// lookup and the color extraction are all stand-ins.

private let streamed = Track(player: .music, id: "00000000000000A1", title: "Streamed", artist: "Artist", album: "Album", isLocalFile: false)
private let localFile = Track(player: .music, id: "00000000000000B2", title: "Ripped", artist: "Artist", album: "CD", isLocalFile: true)
/// Read by a script, which can't say where the track lives.
private let scripted = Track(player: .music, id: "00000000000000C3", title: "Seen by script", artist: "Artist", album: "Album")
private let spotifyTrack = Track(player: .spotify, id: "spotify:track:1", title: "Song", artist: "Band", album: "Record")

/// A palette told apart by one number, standing in for a cover's colors.
private func palette(_ shade: UInt8) -> GlowPalette {
    let value = Double(shade) / 255
    return GlowPalette(primary: PaletteColor(red: value, green: 0, blue: 0), secondary: PaletteColor(red: 0, green: value, blue: 0), balance: 0.5)
}

/// "Extracts" `palette(first byte)` from any artwork.
private let fakeExtract: @Sendable (Data) -> ColorExtractor.Result? = { data in
    data.first.map { ColorExtractor.Result(palette: palette($0), source: .artwork) }
}

/// Polls `condition` a thousand times, five milliseconds apart — longer while the main actor is busy.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// Lets queued work (extraction, lookups, queries) run before checking that something didn't happen.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(80))
}

@MainActor
private func freshSettings() -> Settings {
    let name = "OpenGlowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return Settings(defaults: defaults)
}

// MARK: - The coordinator

/// Stands in for NowPlayingMonitor: the test says what plays and when artwork arrives.
@MainActor
private final class FakeNowPlaying: NowPlayingSource {
    var status: NowPlayingMonitor.Status = .stopped
    var players: Set<Player> = Set(Player.allCases)
    var onStatusChange: ((NowPlayingMonitor.Status) -> Void)?
    var onArtwork: ((Track, Data?) -> Void)?
    private(set) var isStarted = false

    func start() {
        isStarted = true
        report(.notPlaying)
    }

    func stop() {
        isStarted = false
        report(.stopped)
    }

    func refresh() {}

    func report(_ newStatus: NowPlayingMonitor.Status) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    func play(_ track: Track) { report(.playing(track)) }

    func deliverArtwork(_ data: Data?, for track: Track) { onArtwork?(track, data) }
}

/// Stands in for the iTunes lookup: records each title asked about, and answers only when the
/// test says so.
private actor FakeCatalog {
    private(set) var requests: [String] = []
    private var waiting: [CheckedContinuation<Data?, Never>] = []

    func lookUp(title: String) async -> Data? {
        requests.append(title)
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Answers every lookup still waiting.
    func answer(_ cover: Data?) {
        waiting.forEach { $0.resume(returning: cover) }
        waiting = []
    }
}

/// What reached the displays.
@MainActor
private final class Screen {
    var palettes: [GlowPalette] = []
    var current: GlowPalette? { palettes.last }
}

@MainActor
private struct Rig {
    let settings = freshSettings()
    let source = FakeNowPlaying()
    let catalog = FakeCatalog()
    let screen = Screen()
    let coordinator: ColorCoordinator

    init() {
        let (catalog, screen) = (self.catalog, self.screen)
        coordinator = ColorCoordinator(
            settings: settings,
            monitor: source,
            lookUpArtwork: { _, _, title in await catalog.lookUp(title: title) },
            extractColors: fakeExtract,
            showPalette: { palette, _ in screen.palettes.append(palette) }
        )
        coordinator.update(animated: false)
    }

    /// What AppDelegate does when the Apple Music or Spotify checkbox changes.
    func follow(music: Bool? = nil, spotify: Bool? = nil) {
        if let music { settings.followAppleMusic = music }
        if let spotify { settings.followSpotify = spotify }
        coordinator.update(animated: true)
    }
}

@Suite("Album colors: following players")
@MainActor
struct ColorFollowTests {
    @Test func turningThePlayingPlayerOffBringsBackTheDefaultColors() async {
        let rig = Rig()
        rig.source.play(spotifyTrack)
        rig.source.deliverArtwork(Data([200]), for: spotifyTrack)
        #expect(await eventually { rig.screen.current == palette(200) })

        rig.follow(spotify: false)
        #expect(rig.source.players == [.music])
        #expect(rig.screen.current == .fallback)
        #expect(rig.coordinator.albumArtPalette == nil)
        #expect(rig.coordinator.albumArtSource == nil)
        #expect(rig.coordinator.effectivePalette == .fallback)
    }

    /// The colors of a player that's off go even when it's no longer the one playing.
    @Test func colorsLeftByAPausedPlayerGoWhenItIsTurnedOff() async {
        let rig = Rig()
        rig.source.play(spotifyTrack)
        rig.source.deliverArtwork(Data([60]), for: spotifyTrack)
        #expect(await eventually { rig.screen.current == palette(60) })
        rig.source.report(.notPlaying)
        #expect(rig.screen.current == palette(60), "between tracks the last colors stay")

        rig.follow(spotify: false)
        #expect(rig.screen.current == .fallback)
    }

    @Test func aLookupStillRunningWhenItsPlayerIsTurnedOffIsDropped() async {
        let rig = Rig()
        rig.source.play(streamed)
        #expect(await eventually { await rig.catalog.requests == ["Streamed"] })

        rig.follow(music: false)
        await rig.catalog.answer(Data([90]))
        await settle()
        #expect(!rig.screen.palettes.contains(palette(90)))
        #expect(rig.coordinator.albumArtPalette == nil)
    }

    @Test func artworkFromAPlayerThatIsOffIsNeverShown() async {
        let rig = Rig()
        rig.source.play(spotifyTrack)
        // Extraction is still running when the player is turned off.
        rig.source.deliverArtwork(Data([70]), for: spotifyTrack)
        rig.follow(spotify: false)
        // A late delivery for the dropped player is ignored too.
        rig.source.deliverArtwork(Data([71]), for: spotifyTrack)
        await settle()
        #expect(!rig.screen.palettes.contains(palette(70)))
        #expect(!rig.screen.palettes.contains(palette(71)))
        #expect(rig.screen.current == .fallback)
    }

    @Test func turningAPlayerBackOnWhileItPlaysColorsTheGlowAtOnce() async {
        let rig = Rig()
        rig.source.play(spotifyTrack)
        rig.source.deliverArtwork(Data([150]), for: spotifyTrack)
        #expect(await eventually { rig.screen.current == palette(150) })
        rig.follow(spotify: false)
        // What the monitor reports while Spotify is off: it doesn't count as running.
        rig.source.report(.noPlayer)
        #expect(rig.screen.current == .fallback)

        rig.follow(spotify: true)
        #expect(rig.source.players == [.music, .spotify])
        // The monitor asks Spotify again and finds the same track playing: its colors are
        // remembered, so they show without waiting for the artwork.
        rig.source.play(spotifyTrack)
        #expect(rig.screen.current == palette(150))
    }

    /// The case the review found never got colored: the track started while Spotify was off.
    @Test func aTrackThatStartedWhileItsPlayerWasOffIsColoredOnceTurnedOn() async {
        let rig = Rig()
        rig.follow(spotify: false)
        rig.follow(spotify: true)
        rig.source.play(spotifyTrack)
        rig.source.deliverArtwork(Data([120]), for: spotifyTrack)
        #expect(await eventually { rig.screen.current == palette(120) })
    }

    @Test func thePlayersAreWatchedOnlyWhenTheyCanColorTheGlow() {
        let rig = Rig()
        #expect(rig.source.isStarted)

        rig.follow(music: false, spotify: false)
        #expect(!rig.source.isStarted, "with no player followed, nothing is watched")
        #expect(rig.source.players.isEmpty)
        #expect(rig.coordinator.nowPlaying == .stopped)

        rig.follow(spotify: true)
        #expect(rig.source.isStarted)
        #expect(rig.source.players == [.spotify])

        rig.settings.colorMode = .preset
        rig.coordinator.update(animated: true)
        #expect(!rig.source.isStarted)
        rig.settings.colorMode = .albumArt
        rig.settings.isEnabled = false
        rig.coordinator.update(animated: true)
        #expect(!rig.source.isStarted)
    }
}

@Suite("Album colors: when the catalog is asked")
@MainActor
struct CatalogLookupPolicyTests {
    @Test func aStreamedMusicTrackIsLookedUpAtOnce() async {
        let rig = Rig()
        rig.source.play(streamed)
        #expect(await eventually { await rig.catalog.requests == ["Streamed"] })
        await rig.catalog.answer(Data([40]))
        #expect(await eventually { rig.screen.current == palette(40) })
    }

    @Test func aLocalFileIsLookedUpOnlyWhenMusicHasNoArtwork() async {
        let rig = Rig()
        rig.source.play(localFile)
        await settle()
        #expect(await rig.catalog.requests.isEmpty)

        rig.source.deliverArtwork(nil, for: localFile)
        #expect(await eventually { await rig.catalog.requests == ["Ripped"] })
        await rig.catalog.answer(nil)
    }

    @Test func aLocalFileWithItsOwnArtworkIsNeverLookedUp() async {
        let rig = Rig()
        rig.source.play(localFile)
        rig.source.deliverArtwork(Data([30]), for: localFile)
        #expect(await eventually { rig.screen.current == palette(30) })
        await settle()
        #expect(await rig.catalog.requests.isEmpty)
    }

    /// At launch, after Try Again or when Music is followed again, a script reports the track,
    /// and a script can't tell a file from a stream: Music's own answer comes first.
    @Test func aTrackOfUnknownOriginWaitsForMusic() async {
        let rig = Rig()
        rig.source.play(scripted)
        await settle()
        #expect(await rig.catalog.requests.isEmpty)

        rig.source.deliverArtwork(nil, for: scripted)
        #expect(await eventually { await rig.catalog.requests == ["Seen by script"] })
        await rig.catalog.answer(nil)
    }

    @Test func spotifyIsLookedUpOnlyWithoutAUsableCover() async {
        let rig = Rig()
        rig.source.play(spotifyTrack)
        await settle()
        #expect(await rig.catalog.requests.isEmpty)

        rig.source.deliverArtwork(nil, for: spotifyTrack)
        #expect(await eventually { await rig.catalog.requests == ["Song"] })
        await rig.catalog.answer(nil)
    }

    /// The early lookup for a streamed track found nothing, then Music says it has no artwork
    /// either: the same track isn't sent again.
    @Test func aTrackIsLookedUpOnceWhileItIsCurrent() async {
        let rig = Rig()
        rig.source.play(streamed)
        #expect(await eventually { await rig.catalog.requests == ["Streamed"] })
        await rig.catalog.answer(nil)
        await settle()
        rig.source.deliverArtwork(nil, for: streamed)
        await settle()
        #expect(await rig.catalog.requests == ["Streamed"])
    }
}

// MARK: - The monitor

/// Stands in for the AppleScript runner: answers from what the test set up, and records every
/// query. A player with no snapshot set answers "access undecided".
private actor FakeScripts: NowPlayingQuerying {
    struct Query: Equatable {
        var player: Player
        var mayPrompt: Bool
    }

    private(set) var queries: [Query] = []
    private(set) var artworkQueries: [String] = []
    private var snapshots: [Player: NowPlayingMonitor.PlayerSnapshot] = [:]
    private var artwork: [String: NowPlayingMonitor.ArtworkFetch] = [:]
    private var holdsArtwork = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func state(of player: Player, mayPrompt: Bool) async -> NowPlayingMonitor.QueryResult {
        queries.append(Query(player: player, mayPrompt: mayPrompt))
        return snapshots[player].map { .snapshot($0) } ?? .consentRequired
    }

    func musicArtwork(expecting trackID: String) async -> NowPlayingMonitor.ArtworkFetch {
        artworkQueries.append(trackID)
        if holdsArtwork { await withCheckedContinuation { held.append($0) } }
        return artwork[trackID] ?? .none
    }

    func playing(_ track: Track?, on player: Player) {
        snapshots[player] = track.map { NowPlayingMonitor.PlayerSnapshot(state: .playing, track: $0) }
    }

    func setArtwork(_ fetch: NowPlayingMonitor.ArtworkFetch, for trackID: String) { artwork[trackID] = fetch }

    func holdArtwork() { holdsArtwork = true }

    func releaseArtwork() {
        holdsArtwork = false
        held.forEach { $0.resume() }
        held = []
    }
}

/// A monitor wired to stand-ins, and what it reported.
@MainActor
private final class MonitorRig {
    let scripts = FakeScripts()
    var running: Set<Player> = []
    private(set) var artwork: [String] = []
    private(set) lazy var monitor: NowPlayingMonitor = {
        let monitor = NowPlayingMonitor(
            scripts: scripts,
            checkRunning: { [unowned self] player, _ in self.running.contains(player) },
            observesPlayers: false
        )
        monitor.onArtwork = { [unowned self] track, _ in self.artwork.append(track.id) }
        return monitor
    }()
}

private let musicTrack = Track(player: .music, id: "BED468AC7302C9C9", title: "Nightcall", artist: "Kavinsky", album: "OutRun")

@Suite("Now playing: followed players only")
@MainActor
struct NowPlayingFollowTests {
    @Test func aPlayerThatIsOffIsNeverAsked() async {
        let rig = MonitorRig()
        rig.running = [.music, .spotify]
        await rig.scripts.playing(musicTrack, on: .music)
        await rig.scripts.playing(spotifyTrack, on: .spotify)
        rig.monitor.players = [.music]
        rig.monitor.start()
        defer { rig.monitor.stop() }
        #expect(await eventually { rig.monitor.status == .playing(musicTrack) })

        // Spotify starts playing, which would normally prompt for access: its notification is
        // ignored, Try Again leaves it alone, and it never counts as playing.
        rig.monitor.handle(.init(player: .spotify, state: .playing, track: spotifyTrack))
        rig.monitor.refresh()
        await settle()
        let queries = await rig.scripts.queries
        #expect(queries.contains(.init(player: .music, mayPrompt: true)), "Try Again still asks Music")
        #expect(!queries.contains { $0.player == .spotify })
        #expect(rig.monitor.status == .playing(musicTrack))
        #expect(!rig.artwork.contains(spotifyTrack.id))
    }

    @Test func withNoPlayerFollowedNothingCounts() async {
        let rig = MonitorRig()
        rig.running = [.music]
        rig.monitor.players = []
        rig.monitor.start()
        defer { rig.monitor.stop() }
        rig.monitor.handle(.init(player: .music, state: .playing, track: musicTrack))
        await settle()
        #expect(rig.monitor.status == .noPlayer)
        #expect(await rig.scripts.queries.isEmpty)
    }

    @Test func turningAPlayerOffForgetsItAndTurningItBackOnDeliversItsArtworkAgain() async {
        let rig = MonitorRig()
        rig.running = [.music]
        await rig.scripts.playing(musicTrack, on: .music)
        await rig.scripts.setArtwork(.image(Data([1, 2, 3])), for: musicTrack.id)
        rig.monitor.start()
        defer { rig.monitor.stop() }
        #expect(await eventually { rig.artwork == [musicTrack.id] })

        rig.monitor.players = [.spotify]
        #expect(rig.monitor.status == .noPlayer, "a player that's off counts as not running")

        rig.monitor.players = [.music, .spotify]
        #expect(await eventually { rig.artwork == [musicTrack.id, musicTrack.id] })
        #expect(rig.monitor.status == .playing(musicTrack))
        let queries = await rig.scripts.queries
        #expect(queries.allSatisfy { !$0.mayPrompt }, "turning a player on never prompts")
        #expect(await rig.scripts.artworkQueries == [musicTrack.id], "the second delivery comes from the cache")
    }

    @Test func artworkThatArrivesAfterPausingWaitsForTheResume() async {
        let rig = MonitorRig()
        rig.running = [.music]
        await rig.scripts.playing(musicTrack, on: .music)
        await rig.scripts.setArtwork(.image(Data([9])), for: musicTrack.id)
        await rig.scripts.holdArtwork()
        rig.monitor.start()
        defer { rig.monitor.stop() }
        #expect(await eventually { await rig.scripts.artworkQueries == [musicTrack.id] })

        rig.monitor.handle(.init(player: .music, state: .paused, track: musicTrack))
        await rig.scripts.releaseArtwork()
        await settle()
        #expect(rig.artwork.isEmpty, "nothing is delivered for a track that isn't playing")

        rig.monitor.handle(.init(player: .music, state: .playing, track: musicTrack))
        #expect(await eventually { rig.artwork == [musicTrack.id] })
        #expect(await rig.scripts.artworkQueries == [musicTrack.id], "delivered from the cache")
    }

    @Test func artworkForATrackThatEndedIsNotDelivered() async {
        let rig = MonitorRig()
        rig.running = [.music]
        await rig.scripts.playing(musicTrack, on: .music)
        await rig.scripts.setArtwork(.image(Data([9])), for: musicTrack.id)
        await rig.scripts.holdArtwork()
        rig.monitor.start()
        defer { rig.monitor.stop() }
        #expect(await eventually { await rig.scripts.artworkQueries == [musicTrack.id] })

        // The next track starts; no query has confirmed it yet when the first one's artwork lands.
        await rig.scripts.playing(nil, on: .music)
        let next = Track(player: .music, id: "0000000000000001", title: "Next", artist: "Kavinsky", album: "OutRun", isLocalFile: false)
        rig.monitor.handle(.init(player: .music, state: .playing, track: next))
        await rig.scripts.releaseArtwork()
        await settle()
        #expect(rig.monitor.status == .playing(next))
        #expect(rig.artwork.isEmpty)
    }
}
