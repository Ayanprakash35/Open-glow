import Foundation
import Testing
@testable import OpenGlow

private typealias Monitor = NowPlayingMonitor
private typealias Record = NowPlayingMonitor.PlayerRecord

/// Spotify or Music quitting in the middle of a track: the monitor drops to `.noPlayer` and
/// nothing it does on the way could relaunch the player. These drive the same pure pieces the
/// monitor runs (`parseNotification`, `PlayerRecord`, `resolveStatus`) through the sequence a quit
/// produces; no player is launched, queried or sent an Apple Event.
@Suite("Lifecycle: a player quitting mid-track")
struct PlayerQuitTests {
    private let spotifyName = "com.spotify.client.PlaybackStateChanged"
    private let musicName = "com.apple.Music.playerInfo"

    private func playing(_ player: Monitor.Player) -> Record {
        let track = Monitor.Track(player: player, id: "spotify:track:1", title: "T", artist: "A", album: "B")
        var record = Record(isRunning: true, generation: 1)
        record.apply(Monitor.PlayerSnapshot(state: .playing, track: track, artworkURL: nil), change: 1)
        return record
    }

    @Test(arguments: [NowPlayingMonitor.Player.spotify, .music])
    func quittingMidTrackEndsInNoPlayer(player: NowPlayingMonitor.Player) throws {
        var record = playing(player)
        #expect(Monitor.resolveStatus(isStarted: true, players: [player: record]).isPlaying)

        // What the player posts as it quits: playback stops (or pauses). Neither asks for a query,
        // so nothing is sent to a process that's on its way out.
        let name = player == .spotify ? spotifyName : musicName
        for state in ["Stopped", "Paused"] {
            var quitting = record
            let notification = try #require(Monitor.parseNotification(name: name, userInfo: ["Player State": state]))
            #expect(quitting.apply(notification, change: 2) == nil, "\(state) must not query a quitting player")
        }
        _ = record.apply(try #require(Monitor.parseNotification(name: name, userInfo: ["Player State": "Stopped"])), change: 2)
        #expect(Monitor.resolveStatus(isStarted: true, players: [player: record]) == .notPlaying)

        // NSWorkspace's quit notification resets the record as not running (the monitor excludes
        // the quitting process even if NSRunningApplication hasn't caught up).
        let afterQuit = Record(isRunning: false, generation: 2)
        #expect(Monitor.resolveStatus(isStarted: true, players: [player: afterQuit]) == .noPlayer)
        #expect(Monitor.resolveStatus(isStarted: true, players: [.music: afterQuit, .spotify: afterQuit]) == .noPlayer)
    }

    /// The other player keeps the status when it still runs.
    @Test func theOtherPlayerStillCounts() {
        let players: [Monitor.Player: Record] = [
            .spotify: Record(isRunning: false, generation: 2),
            .music: Record(isRunning: true, state: .paused, generation: 1),
        ]
        #expect(Monitor.resolveStatus(isStarted: true, players: players) == .notPlaying)
    }

    /// A query already in flight when the player quits comes back as "not running" — the script's
    /// own guard, or the event failing because the process is gone — never as a failure to retry.
    @Test func aQueryRacingTheQuitReadsAsNotRunning() {
        #expect(NowPlayingScript.result(forErrorCode: -600) == .notRunning)
        #expect(NowPlayingScript.result(forErrorCode: -609) == .notRunning)
        for script in NowPlayingScript.all {
            // Every script checks first, so a player that's already gone isn't launched by `tell`.
            #expect(script.source.hasPrefix(#"if application id "\#(script.player.bundleIdentifier)" is running then"#))
        }
    }
}

private extension NowPlayingMonitor.Status {
    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}
