import AppKit
import Testing
@testable import OpenGlow

private typealias Monitor = NowPlayingMonitor
private typealias Track = NowPlayingMonitor.Track
private typealias Record = NowPlayingMonitor.PlayerRecord

private let musicName = "com.apple.Music.playerInfo"
private let spotifyName = "com.spotify.client.PlaybackStateChanged"

/// Trimmed-down copies of what Music and Spotify actually post.
private var musicPlayingInfo: [AnyHashable: Any] {
    [
        "Player State": "Playing",
        "Name": "Nightcall",
        "Artist": "Kavinsky",
        "Album": "OutRun",
        "Album Artist": "Kavinsky",
        "PersistentID": NSNumber(value: Int64(-4_696_013_421_567_358_519)),
        "Library PersistentID": NSNumber(value: Int64(1_311_768_467_294_899_695)),
        "Total Time": 258_000,
        "Track Number": 2,
        "Artwork Count": 1,
        "Store URL": "itms://itunes.com/album?p=1&i=2",
    ]
}

private var spotifyPlayingInfo: [AnyHashable: Any] {
    [
        "Player State": "Playing",
        "Name": "Midnight City",
        "Artist": "M83",
        "Album": "Hurry Up, We're Dreaming",
        "Album Artist": "M83",
        "Track ID": "spotify:track:1eyzqe2QqGZUmfcPZtrIyt",
        "Duration": 243_960,
        "Playback Position": 0.0,
        "Has Artwork": true,
        "Popularity": 76,
        "Starred": false,
        "Disc Number": 1,
        "Track Number": 1,
    ]
}

private func updating(_ info: [AnyHashable: Any], _ changes: [AnyHashable: Any?]) -> [AnyHashable: Any] {
    var result = info
    for (key, value) in changes { result[key] = value }
    return result
}

private let nightcall = Track(player: .music, id: "BED468AC7302C9C9", title: "Nightcall", artist: "Kavinsky", album: "OutRun")
private let midnightCity = Track(player: .spotify, id: "spotify:track:1eyzqe2QqGZUmfcPZtrIyt", title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming")

@Suite("Now playing: notifications")
struct NowPlayingNotificationTests {
    @Test func musicPlaying() {
        let event = Monitor.parseNotification(name: musicName, userInfo: musicPlayingInfo)
        #expect(event == .init(player: .music, state: .playing, track: nightcall))
    }

    @Test func musicPausedKeepsTheTrack() {
        let event = Monitor.parseNotification(name: musicName, userInfo: updating(musicPlayingInfo, ["Player State": "Paused"]))
        #expect(event == .init(player: .music, state: .paused, track: nightcall))
    }

    /// Music's stopped notification carries little more than the state.
    @Test func musicStopped() {
        let info: [AnyHashable: Any] = ["Player State": "Stopped", "Library PersistentID": NSNumber(value: 42)]
        #expect(Monitor.parseNotification(name: musicName, userInfo: info) == .init(player: .music, state: .stopped, track: nil))
    }

    /// Radio streams arrive without a persistent ID: the state is kept, the track isn't guessed.
    @Test func musicWithoutPersistentIDHasNoTrack() {
        let info = updating(musicPlayingInfo, ["PersistentID": nil, "Stream Title": "Now: Something"])
        #expect(Monitor.parseNotification(name: musicName, userInfo: info) == .init(player: .music, state: .playing, track: nil))
    }

    @Test func missingTextFieldsBecomeEmpty() {
        let info = updating(musicPlayingInfo, ["Artist": nil, "Album": nil])
        let event = Monitor.parseNotification(name: musicName, userInfo: info)
        #expect(event?.track?.artist == "")
        #expect(event?.track?.album == "")
        #expect(event?.track?.title == "Nightcall")
    }

    @Test func missingOrUnknownStateIsNil() {
        let noState = updating(musicPlayingInfo, ["Player State": nil])
        #expect(Monitor.parseNotification(name: musicName, userInfo: noState)?.state == nil)
        let odd = updating(spotifyPlayingInfo, ["Player State": "Buffering"])
        #expect(Monitor.parseNotification(name: spotifyName, userInfo: odd)?.state == nil)
    }

    @Test func spotifyPlayingPausedStopped() {
        #expect(Monitor.parseNotification(name: spotifyName, userInfo: spotifyPlayingInfo) == .init(player: .spotify, state: .playing, track: midnightCity))
        let paused = updating(spotifyPlayingInfo, ["Player State": "Paused"])
        #expect(Monitor.parseNotification(name: spotifyName, userInfo: paused) == .init(player: .spotify, state: .paused, track: midnightCity))
        // Spotify still sends the last track's fields when stopping; a stopped player has no track.
        let stopped = updating(spotifyPlayingInfo, ["Player State": "Stopped"])
        #expect(Monitor.parseNotification(name: spotifyName, userInfo: stopped) == .init(player: .spotify, state: .stopped, track: nil))
    }

    @Test func spotifyWithoutTrackIDHasNoTrack() {
        let info = updating(spotifyPlayingInfo, ["Track ID": nil])
        #expect(Monitor.parseNotification(name: spotifyName, userInfo: info) == .init(player: .spotify, state: .playing, track: nil))
        let empty = updating(spotifyPlayingInfo, ["Track ID": ""])
        #expect(Monitor.parseNotification(name: spotifyName, userInfo: empty)?.track == nil)
    }

    @Test func otherNotificationsAreIgnored() {
        #expect(Monitor.parseNotification(name: "com.apple.iTunes.playerInfo", userInfo: musicPlayingInfo) == nil)
    }

    /// The notification's signed number and AppleScript's hex text must name the same track, or
    /// every notification would look like a track change.
    @Test func musicIDsAgreeBetweenNotificationAndScript() {
        #expect(Monitor.musicID(fromNotificationValue: NSNumber(value: Int64(-4_696_013_421_567_358_519))) == "BED468AC7302C9C9")
        #expect(Monitor.musicID(fromNotificationValue: 1_234_567_890) == "00000000499602D2")
        #expect(Monitor.canonicalMusicID("bed468ac7302c9c9") == "BED468AC7302C9C9")
        #expect(Monitor.canonicalMusicID("499602D2") == "00000000499602D2")
        #expect(Monitor.canonicalMusicID("not-hex") == "not-hex")
        #expect(Monitor.musicID(fromNotificationValue: nil) == nil)
    }
}

@Suite("Now playing: deciding when to query")
struct NowPlayingRecordTests {
    @Test func playbackStartingAsksAndMayPrompt() {
        var record = Record(isRunning: true)
        let query = record.apply(.init(player: .music, state: .playing, track: nightcall), change: 7)
        #expect(query == .mayPrompt)
        #expect(record.state == .playing)
        #expect(record.track == nightcall)
        #expect(record.lastChange == 7)
    }

    @Test func resumingAConfirmedTrackSendsNothing() {
        var record = Record(isRunning: true, state: .paused, track: nightcall, confirmedTrackID: nightcall.id)
        #expect(record.apply(.init(player: .music, state: .playing, track: nightcall), change: 1) == nil)
    }

    /// Denied access is only retried on the player's next notification, never by the poll.
    @Test func aDeniedPlayerIsRetriedOnItsNextNotification() {
        var record = Record(isRunning: true, state: .playing, track: nightcall, isBlocked: true, confirmedTrackID: nightcall.id)
        #expect(record.apply(.init(player: .music, state: .playing, track: nightcall), change: 1) == .mayPrompt)
    }

    @Test func pausingAndStoppingSendNothing() {
        var record = Record(isRunning: true, state: .playing, track: nightcall)
        #expect(record.apply(.init(player: .music, state: .paused, track: nil), change: 1) == nil)
        #expect(record.track == nightcall, "a paused notification without fields keeps the track")
        #expect(record.apply(.init(player: .music, state: .stopped, track: nil), change: 2) == nil)
        #expect(record.track == nil)
    }

    @Test func aNotificationWithoutStateQueriesSilently() {
        var record = Record(isRunning: true)
        #expect(record.apply(.init(player: .spotify, state: nil, track: nil), change: 3) == .silent)
        #expect(record.lastChange == 3)
    }

    @Test func aSnapshotConfirmsTheTrackAndClearsTheDenial() {
        var record = Record(isRunning: true, state: .playing, track: midnightCity, lastChange: 4, isBlocked: true)
        let url = URL(string: "https://i.scdn.co/image/ab67616d0000b273")
        record.apply(.init(state: .playing, track: midnightCity, artworkURL: url), change: 9)
        #expect(!record.isBlocked)
        #expect(record.confirmedTrackID == midnightCity.id)
        #expect(record.artworkURL == url)
        #expect(record.lastChange == 4, "nothing changed, so the order of changes stays")

        record.apply(.init(state: .paused, track: midnightCity), change: 10)
        #expect(record.lastChange == 10)
    }
}

@Suite("Now playing: status")
struct NowPlayingStatusTests {
    private func resolve(_ players: [Monitor.Player: Record], started: Bool = true) -> Monitor.Status {
        Monitor.resolveStatus(isStarted: started, players: players)
    }

    @Test func stoppedAndNoPlayer() {
        #expect(resolve([.music: Record(isRunning: true, state: .playing, track: nightcall)], started: false) == .stopped)
        #expect(resolve([:]) == .noPlayer)
        #expect(resolve([.music: Record(), .spotify: Record()]) == .noPlayer)
    }

    @Test func runningButNotPlaying() {
        #expect(resolve([.music: Record(isRunning: true)]) == .notPlaying)
        #expect(resolve([.music: Record(isRunning: true, state: .paused, track: nightcall)]) == .notPlaying)
    }

    @Test func playing() {
        let players: [Monitor.Player: Record] = [
            .music: Record(isRunning: true, state: .paused, track: nightcall, lastChange: 5),
            .spotify: Record(isRunning: true, state: .playing, track: midnightCity, lastChange: 2),
        ]
        #expect(resolve(players) == .playing(midnightCity))
    }

    @Test func bothPlayingPrefersTheMostRecentChange() {
        var players: [Monitor.Player: Record] = [
            .music: Record(isRunning: true, state: .playing, track: nightcall, lastChange: 3),
            .spotify: Record(isRunning: true, state: .playing, track: midnightCity, lastChange: 8),
        ]
        #expect(resolve(players) == .playing(midnightCity))
        players[.music]?.lastChange = 9
        #expect(resolve(players) == .playing(nightcall))
    }

    @Test func aPlayerThatQuitDoesNotCount() {
        let players: [Monitor.Player: Record] = [
            .music: Record(isRunning: false, state: .playing, track: nightcall, lastChange: 9),
            .spotify: Record(isRunning: true, state: .paused, track: midnightCity, lastChange: 1),
        ]
        #expect(resolve(players) == .notPlaying)
    }

    @Test func playingWithoutAnIdentifiableTrack() {
        let status = resolve([.music: Record(isRunning: true, state: .playing, track: nil)])
        #expect(status == .playing(Track(player: .music, id: "", title: "", artist: "", album: "")))
    }

    /// -1743 maps to `.notAuthorized`, and the status shows it when it matters.
    @Test func deniedAccess() {
        #expect(Monitor.QueryResult.notAuthorized == NowPlayingScript.result(forErrorCode: -1743))
        // Playing according to its notification, but we may not ask it anything.
        #expect(resolve([.spotify: Record(isRunning: true, state: .playing, track: midnightCity, isBlocked: true)]) == .notAuthorized(.spotify))
        // Denied at start(), state unknown.
        #expect(resolve([.music: Record(isRunning: true, isBlocked: true)]) == .notAuthorized(.music))
        // Known to be paused: nothing to miss.
        #expect(resolve([.music: Record(isRunning: true, state: .paused, isBlocked: true)]) == .notPlaying)
        // Another player that plays wins over a denied one whose state is unknown.
        let mixed: [Monitor.Player: Record] = [
            .music: Record(isRunning: true, lastChange: 5, isBlocked: true),
            .spotify: Record(isRunning: true, state: .playing, track: midnightCity, lastChange: 1),
        ]
        #expect(resolve(mixed) == .playing(midnightCity))
    }
}

@Suite("Now playing: errors and artwork URLs")
struct NowPlayingErrorTests {
    @Test(arguments: [
        (-1743, NowPlayingMonitor.QueryResult.notAuthorized),
        (-1744, .consentRequired),
        (-600, .notRunning),
        (-609, .notRunning),
        (-1712, .timedOut),
        (-1708, .failed(code: -1708)),
        (-1728, .failed(code: -1728)),
    ])
    func errorCodes(code: Int, expected: NowPlayingMonitor.QueryResult) {
        #expect(NowPlayingScript.result(forErrorCode: code) == expected)
    }

    @Test func artworkURLsAreHTTPSOnly() {
        #expect(Monitor.artworkURL(from: "https://i.scdn.co/image/ab67616d0000b273")?.absoluteString == "https://i.scdn.co/image/ab67616d0000b273")
        #expect(Monitor.artworkURL(from: " http://i.scdn.co/image/abc\n")?.absoluteString == "https://i.scdn.co/image/abc")
        #expect(Monitor.artworkURL(from: "file:///etc/hosts") == nil)
        #expect(Monitor.artworkURL(from: "data:image/png;base64,AAAA") == nil)
        #expect(Monitor.artworkURL(from: "ftp://example.com/a.jpg") == nil)
        #expect(Monitor.artworkURL(from: "") == nil)
        #expect(Monitor.artworkURL(from: "not a url") == nil)
    }

    /// Refused before any network use.
    @Test func downloadRefusesNonHTTPS() async {
        #expect(await Monitor.downloadArtwork(from: nil, using: .shared) == .none)
        #expect(await Monitor.downloadArtwork(from: URL(string: "file:///etc/hosts"), using: .shared) == .none)
    }

    @Test func artworkCacheKeepsTheMostRecentlyUsed() {
        var cache = Monitor.ArtworkCache(capacity: 2)
        let a = Monitor.ArtworkKey(player: .music, id: "A")
        let b = Monitor.ArtworkKey(player: .spotify, id: "B")
        let c = Monitor.ArtworkKey(player: .spotify, id: "C")
        cache.store(.image(Data([1])), for: a)
        cache.store(.none, for: b)
        #expect(cache.lookup(a) == .image(Data([1])))
        cache.store(.image(Data([3])), for: c)
        #expect(cache.lookup(b) == nil, "b was least recently used")
        #expect(cache.lookup(a) == .image(Data([1])))
        #expect(cache.lookup(c) == .image(Data([3])))
        cache.store(.none, for: c)
        #expect(cache.lookup(c) == Monitor.ArtworkFetch.none, "a track without artwork is remembered too")
        #expect(cache.entries.count == 2)
    }
}

// MARK: - Script replies

private func code(_ text: String) -> OSType { NowPlayingScript.fourCharCode(text) }
private func text(_ value: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: value) }
private func state(_ value: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(enumCode: code(value)) }
private var missingValue: NSAppleEventDescriptor { NSAppleEventDescriptor(typeCode: NowPlayingScript.fourCharCode("msng")) }

private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (offset, item) in items.enumerated() { list.insert(item, at: offset + 1) }
    return list
}

/// Runs AppleScript that targets no application — plain literals, evaluated in this process — to
/// get replies encoded exactly as AppleScript encodes them.
private func evaluate(_ source: String) throws -> NSAppleEventDescriptor {
    let script = try #require(NSAppleScript(source: source))
    var errorInfo: NSDictionary?
    let reply = script.executeAndReturnError(&errorInfo)
    try #require(errorInfo == nil, "\(String(describing: errorInfo))")
    return reply
}

private func isInstalled(_ player: Monitor.Player) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
}

private func isRunning(_ player: Monitor.Player) -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).contains { !$0.isTerminated }
}

/// Serialized: every test here uses the AppleScript component.
@Suite("Now playing: scripts", .serialized)
struct NowPlayingScriptTests {
    @Test func musicPlayingReply() {
        let reply = list([state("kPSP"), text("bed468ac7302c9c9"), text("Nightcall"), text("Kavinsky"), text("OutRun")])
        #expect(NowPlayingScript.parseState(reply, player: .music) == .snapshot(.init(state: .playing, track: nightcall)))
    }

    @Test func spotifyReplyWithArtworkURL() {
        let reply = list([
            state("kPSp"), text(midnightCity.id), text("Midnight City"), text("M83"), text("Hurry Up, We're Dreaming"),
            text("http://i.scdn.co/image/ab67616d0000b273"),
        ])
        let expected = Monitor.PlayerSnapshot(state: .paused, track: midnightCity, artworkURL: URL(string: "https://i.scdn.co/image/ab67616d0000b273"))
        #expect(NowPlayingScript.parseState(reply, player: .spotify) == .snapshot(expected))
    }

    @Test func spotifyReplyWithoutArtwork() {
        let reply = list([state("kPSP"), text("spotify:local:x"), text("Demo"), missingValue, text(""), text("")])
        let track = Track(player: .spotify, id: "spotify:local:x", title: "Demo", artist: "", album: "")
        #expect(NowPlayingScript.parseState(reply, player: .spotify) == .snapshot(.init(state: .playing, track: track, artworkURL: nil)))
    }

    @Test func stoppedNotRunningAndTracklessReplies() {
        #expect(NowPlayingScript.parseState(list([state("kPSS")]), player: .music) == .snapshot(.init(state: .stopped)))
        #expect(NowPlayingScript.parseState(list([]), player: .spotify) == .notRunning)
        // A radio stream without a scriptable current track (-1728 caught in the script).
        #expect(NowPlayingScript.parseState(list([state("kPSP")]), player: .music) == .snapshot(.init(state: .playing)))
        // Fast forwarding still counts as playing.
        #expect(NowPlayingScript.parseState(list([state("kPSF")]), player: .music) == .snapshot(.init(state: .playing)))
    }

    @Test func unrecognizedReplies() {
        #expect(NowPlayingScript.parseState(list([state("zzzz")]), player: .music) == .failed(code: -1700))
        #expect(NowPlayingScript.parseState(text("playing"), player: .music) == .failed(code: -1700))
    }

    @Test func musicArtworkReplies() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let artwork = try #require(NSAppleEventDescriptor(descriptorType: code("tdta"), data: jpeg))
        #expect(NowPlayingScript.parseMusicArtwork(list([text(nightcall.id), artwork]), expecting: nightcall.id) == .image(jpeg))
        // No artwork: the script returns just the ID.
        #expect(NowPlayingScript.parseMusicArtwork(list([text(nightcall.id)]), expecting: nightcall.id) == .none)
        #expect(NowPlayingScript.parseMusicArtwork(list([text(nightcall.id), missingValue]), expecting: nightcall.id) == .none)
        // The track changed between the state query and this one.
        #expect(NowPlayingScript.parseMusicArtwork(list([text("0000000000000001"), artwork]), expecting: nightcall.id) == .unavailable)
        // Music quit.
        #expect(NowPlayingScript.parseMusicArtwork(list([]), expecting: nightcall.id) == .unavailable)
    }

    @Test func oversizedArtworkCountsAsNone() throws {
        let huge = Data(count: NowPlayingConfig.maxArtworkBytes + 1)
        let artwork = try #require(NSAppleEventDescriptor(descriptorType: code("PNGf"), data: huge))
        #expect(NowPlayingScript.parseMusicArtwork(list([text(nightcall.id), artwork]), expecting: nightcall.id) == .none)
    }

    /// The same shapes, but encoded by AppleScript itself: raw «constant» and «data» literals
    /// need no dictionary and involve no application.
    @Test func repliesEncodedByAppleScript() throws {
        let music = try evaluate(#"return {«constant ****kPSP», "BED468AC7302C9C9", "Nightcall", "Kavinsky", missing value}"#)
        let expected = Track(player: .music, id: nightcall.id, title: "Nightcall", artist: "Kavinsky", album: "")
        #expect(NowPlayingScript.parseState(music, player: .music) == .snapshot(.init(state: .playing, track: expected)))

        let spotify = try evaluate(#"return {«constant ****kPSp», "spotify:track:1eyzqe2QqGZUmfcPZtrIyt", "Midnight City", "M83", "Hurry Up, We're Dreaming", "https://i.scdn.co/image/x"}"#)
        let snapshot = Monitor.PlayerSnapshot(state: .paused, track: midnightCity, artworkURL: URL(string: "https://i.scdn.co/image/x"))
        #expect(NowPlayingScript.parseState(spotify, player: .spotify) == .snapshot(snapshot))

        #expect(NowPlayingScript.parseState(try evaluate("return {«constant ****kPSS»}"), player: .spotify) == .snapshot(.init(state: .stopped)))
        #expect(NowPlayingScript.parseState(try evaluate("return {}"), player: .music) == .notRunning)

        let artwork = try evaluate(#"return {"BED468AC7302C9C9", «data tdtaFFD8FFE000104A46»}"#)
        #expect(NowPlayingScript.parseMusicArtwork(artwork, expecting: nightcall.id) == .image(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])))
    }

    @Test func everyScriptIsGuardedAndTimed() {
        for script in NowPlayingScript.all {
            let source = script.source
            #expect(source.hasPrefix(#"if application id "\#(script.player.bundleIdentifier)" is running then"#))
            #expect(source.contains(#"tell application id "\#(script.player.bundleIdentifier)""#))
            #expect(source.contains("with timeout of"))
            #expect(source.hasSuffix("return {}"))
        }
    }

    // Compiling reads the player's dictionary from its bundle (both declare a static sdef): it
    // neither launches the player nor sends it an event. Nothing here executes these scripts.
    @Test(.enabled(if: isInstalled(.music)))
    func musicScriptsCompile() throws {
        try expectCompiles([.state(.music), .musicArtwork])
    }

    @Test(.enabled(if: isInstalled(.spotify)))
    func spotifyScriptCompiles() throws {
        try expectCompiles([.state(.spotify)])
    }

    private func expectCompiles(_ scripts: [NowPlayingScript]) throws {
        for script in scripts {
            let wasRunning = isRunning(script.player)
            let appleScript = try #require(NSAppleScript(source: script.source))
            var errorInfo: NSDictionary?
            let compiled = appleScript.compileAndReturnError(&errorInfo)
            #expect(compiled, "\(script): \(String(describing: errorInfo))")
            #expect(appleScript.isCompiled)
            #expect(isRunning(script.player) == wasRunning, "compiling must not launch or quit \(script.player.displayName)")
        }
    }
}
