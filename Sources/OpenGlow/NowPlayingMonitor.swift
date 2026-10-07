import AppKit
import os

/// Now-playing tuning.
enum NowPlayingConfig {
    /// Seconds between safety re-queries while a supported player runs, in case a notification was
    /// missed. Sane range: 10–60.
    static let pollInterval: TimeInterval = 15
    /// Seconds the safety poll may drift so macOS can batch it with other wakeups. Sane range:
    /// 1–pollInterval/2.
    static let pollTolerance: TimeInterval = 5
    /// Seconds a Spotify artwork download may take in all before it's abandoned. Sane range: 5–30.
    static let downloadTimeout: TimeInterval = 10
    /// Largest artwork accepted from either player, in bytes; bigger images count as none.
    /// Sane range: 2–16 MB.
    static let maxArtworkBytes = 8 * 1024 * 1024
    /// Tracks whose artwork (or lack of it) is remembered, so going back to one never refetches.
    /// Sane range: 2–10.
    static let artworkCacheSize = 4
}

/// Reports what Apple Music or Spotify is playing, and fetches each new track's artwork.
///
/// Event-driven: the players' distributed notifications say when something changed (and carry
/// the state and track), NSWorkspace says when a player launches or quits. Apple Events — via
/// `NowPlayingScriptRunner`, never on the main thread — fill in what notifications don't have:
/// the state at `start()`, Music's artwork and Spotify's artwork URL. A slow safety poll runs only
/// while a supported player does. The private MediaRemote framework is not used.
///
/// The Automation prompt should appear when it makes sense to the user, not at app launch: only
/// a query that follows playback starting in a player, or `refresh()`, may show it. Every other
/// query first checks — without prompting — that access is already granted, and is skipped if
/// not. Needs NSAppleEventsUsageDescription in Info.plist.
///
/// Meant to live as long as the app; call `stop()` before letting go of one.
@MainActor
final class NowPlayingMonitor {
    enum Player: String, CaseIterable, Sendable {
        case music, spotify

        var bundleIdentifier: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }

        var displayName: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            }
        }
    }

    struct Track: Equatable, Sendable {
        var player: Player
        /// Music: the 16-digit uppercase hex persistent ID. Spotify: the track URI
        /// ("spotify:track:…"). Empty when the player can't identify what it plays.
        var id: String
        var title: String
        var artist: String
        var album: String
    }

    enum Status: Equatable, Sendable {
        /// The monitor isn't started.
        case stopped
        /// Neither Music nor Spotify is running.
        case noPlayer
        /// A player runs but nothing is playing (or it hasn't said yet).
        case notPlaying
        case playing(Track)
        /// The user denied Automation access to this player, and it is (or may be) the one playing.
        case notAuthorized(Player)
    }

    private(set) var status: Status = .stopped
    /// Main actor, whenever `status` changes.
    var onStatusChange: ((Status) -> Void)?
    /// Main actor, once per newly playing track: its artwork image data, or nil when the track
    /// has none or it couldn't be fetched. Not repeated for the same track — pausing and resuming
    /// doesn't repeat it, so keep the last artwork alongside its track — but repeated when the
    /// monitor restarts or the player relaunches.
    var onArtwork: ((Track, Data?) -> Void)?

    private let logger = Logger(subsystem: "com.openglow.app", category: "NowPlaying")
    private let scripts = NowPlayingScriptRunner()
    private var observer: NowPlayingObserver?
    private var pollTimer: Timer?
    private var isStarted = false
    private var records: [Player: PlayerRecord] = [:]
    /// Source of `PlayerRecord.generation`.
    private var generationCounter = 0
    /// Source of `PlayerRecord.lastChange`.
    private var changeCounter = 0
    private var queriesInFlight: Set<Player> = []
    /// Players asked about again while a query to them was in flight, and how.
    private var requeries: [Player: PromptPolicy] = [:]
    /// The track whose artwork was last requested or delivered.
    private var artworkKey: ArtworkKey?
    private var artworkInFlight: Set<ArtworkKey> = []
    private var artworkCache = ArtworkCache(capacity: NowPlayingConfig.artworkCacheSize)

    /// Ephemeral: no cookies, no disk cache. Artwork is kept in `artworkCache` instead.
    nonisolated private static let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = NowPlayingConfig.downloadTimeout
        configuration.timeoutIntervalForResource = NowPlayingConfig.downloadTimeout
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observer = NowPlayingObserver(
            onPlayerInfo: { [weak self] in self?.handle($0) },
            onLaunch: { [weak self] in self?.playerLaunched($0) },
            onQuit: { [weak self] in self?.playerQuit($0) }
        )
        for player in Player.allCases {
            records[player] = PlayerRecord(isRunning: Self.isRunning(player), generation: nextGeneration())
        }
        logger.notice("Now-playing monitor started")
        recomputeStatus()
        for player in Player.allCases where records[player]?.isRunning == true {
            requestQuery(player, .silent)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observer?.invalidate()
        observer = nil
        // In-flight queries find no record with their generation and are dropped; in-flight
        // artwork still lands in the cache.
        records = [:]
        queriesInFlight = []
        requeries = [:]
        artworkKey = nil
        logger.notice("Now-playing monitor stopped")
        recomputeStatus()
    }

    /// Re-query now (e.g. after the user grants Automation access in System Settings). Also
    /// retries a player marked not authorized. May show the Automation prompt if the user hasn't
    /// decided yet, so call it from a user action.
    func refresh() {
        guard isStarted else { return }
        syncRunningPlayers()
        for player in Player.allCases where records[player]?.isRunning == true {
            requestQuery(player, .mayPrompt)
        }
    }

    // MARK: - Events

    private func handle(_ notification: PlayerNotification) {
        guard isStarted else { return }
        let player = notification.player
        var record = records[player] ?? PlayerRecord(generation: nextGeneration())
        record.isRunning = Self.isRunning(player)
        let query = record.apply(notification, change: nextChange())
        records[player] = record
        logger.debug("\(player.displayName, privacy: .public) notification: \(notification.state.map { "\($0)" } ?? "no state", privacy: .public)")
        recomputeStatus()
        if let query { requestQuery(player, query) }
    }

    private func playerLaunched(_ player: Player) {
        // Already known to run when its first notification beat NSWorkspace's: keep what it said.
        guard isStarted, records[player]?.isRunning != true else { return }
        resetRecord(player, isRunning: true)
        logger.info("\(player.displayName, privacy: .public) launched")
        // Nothing is sent yet: a player that starts playing says so, and the poll covers the rest.
        recomputeStatus()
    }

    private func playerQuit(_ player: Player) {
        guard isStarted else { return }
        resetRecord(player, isRunning: Self.isRunning(player))
        // A relaunch counts as a new session: its first track gets its artwork delivered again.
        if artworkKey?.player == player { artworkKey = nil }
        logger.info("\(player.displayName, privacy: .public) quit")
        recomputeStatus()
    }

    /// Starts `player` over. Queries still in flight carry the old generation and are dropped.
    private func resetRecord(_ player: Player, isRunning: Bool) {
        records[player] = PlayerRecord(isRunning: isRunning, generation: nextGeneration())
        queriesInFlight.remove(player)
        requeries[player] = nil
    }

    /// Catches a launch or quit whose notification was missed.
    private func syncRunningPlayers() {
        for player in Player.allCases {
            let running = Self.isRunning(player)
            guard running != records[player]?.isRunning else { continue }
            if running { playerLaunched(player) } else { playerQuit(player) }
        }
    }

    private func poll() {
        guard isStarted else { return }
        syncRunningPlayers()
        // A player marked not authorized is left alone until its next notification or refresh().
        for player in Player.allCases where records[player]?.isRunning == true && records[player]?.isBlocked == false {
            requestQuery(player, .silent)
        }
    }

    private func updatePollTimer() {
        let wanted = isStarted && records.values.contains { $0.isRunning }
        if wanted, pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: NowPlayingConfig.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = NowPlayingConfig.pollTolerance
            pollTimer = timer
        } else if !wanted, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Queries

    /// At most one query per player is in flight; asking again meanwhile queues one more.
    private func requestQuery(_ player: Player, _ policy: PromptPolicy) {
        guard isStarted, let record = records[player], record.isRunning else { return }
        guard !queriesInFlight.contains(player) else {
            requeries[player] = requeries[player] == .mayPrompt ? .mayPrompt : policy
            return
        }
        queriesInFlight.insert(player)
        let generation = record.generation
        let scripts = self.scripts
        Task { [weak self] in
            let result = await scripts.state(of: player, mayPrompt: policy == .mayPrompt)
            self?.finishQuery(player, generation: generation, result: result)
        }
    }

    private func finishQuery(_ player: Player, generation: Int, result: QueryResult) {
        guard var record = records[player], record.generation == generation else { return }
        queriesInFlight.remove(player)
        if let again = requeries.removeValue(forKey: player) {
            // Something changed while this query ran, so its answer may already be stale.
            requestQuery(player, again)
            return
        }
        switch result {
        case .snapshot(let snapshot):
            if record.isBlocked {
                logger.notice("\(player.displayName, privacy: .public) Automation access is granted now")
            }
            record.apply(snapshot, change: nextChange())
        case .notRunning:
            // It just quit; NSWorkspace's notification follows.
            record.isRunning = Self.isRunning(player)
            record.state = nil
            record.track = nil
        case .notAuthorized:
            if !record.isBlocked {
                logger.error("\(player.displayName, privacy: .public) Automation access denied (-1743); not asking it again until refresh() or its next notification")
            }
            record.isBlocked = true
        case .consentRequired:
            logger.debug("\(player.displayName, privacy: .public) not queried: Automation access undecided, waiting for playback to start")
        case .timedOut:
            logger.notice("\(player.displayName, privacy: .public) didn't answer in time; keeping the previous state")
        case .failed(let code):
            logger.error("\(player.displayName, privacy: .public) query failed: \(code, privacy: .public)")
        }
        records[player] = record
        recomputeStatus()
    }

    private func recomputeStatus() {
        let newStatus = Self.resolveStatus(isStarted: isStarted, players: records)
        if newStatus != status {
            status = newStatus
            logStatus()
            onStatusChange?(newStatus)
        }
        updateArtwork()
        updatePollTimer()
    }

    private func logStatus() {
        switch status {
        case .playing(let track):
            logger.info("Playing on \(track.player.displayName, privacy: .public): \(track.title, privacy: .private) by \(track.artist, privacy: .private)")
        case .notAuthorized(let player):
            logger.info("Not authorized for \(player.displayName, privacy: .public)")
        default:
            logger.info("Now playing: \(String(describing: self.status), privacy: .public)")
        }
    }

    // MARK: - Artwork

    private func updateArtwork() {
        guard case .playing(let track) = status else { return }
        let key = ArtworkKey(player: track.player, id: track.id)
        guard key != artworkKey else { return }
        if track.id.isEmpty {
            artworkKey = key
            onArtwork?(track, nil)
            return
        }
        if let cached = artworkCache.lookup(key) {
            artworkKey = key
            onArtwork?(track, cached.data)
            return
        }
        // Wait until a query has confirmed this track: that also means access is granted, and for
        // Spotify it brings the artwork URL.
        guard let record = records[track.player], record.confirmedTrackID == track.id else { return }
        artworkKey = key
        guard !artworkInFlight.contains(key) else { return }
        artworkInFlight.insert(key)

        let scripts = self.scripts
        let url = record.artworkURL
        Task { [weak self] in
            let fetch: ArtworkFetch
            switch track.player {
            case .music:
                fetch = await scripts.musicArtwork(expecting: track.id)
            case .spotify:
                // Detached so the download's byte loop runs off the main actor whatever the
                // default isolation of nonisolated async functions.
                fetch = await Task.detached(priority: .utility) {
                    await Self.downloadArtwork(from: url, using: Self.artworkSession)
                }.value
            }
            self?.finishArtwork(track, key: key, fetch: fetch)
        }
    }

    private func finishArtwork(_ track: Track, key: ArtworkKey, fetch: ArtworkFetch) {
        artworkInFlight.remove(key)
        if fetch.isDefinitive { artworkCache.store(fetch, for: key) }
        logger.debug("Artwork for \(track.player.displayName, privacy: .public) track: \(fetch.data?.count ?? 0, privacy: .public) bytes")
        // Dropped if a newer track took over or the monitor stopped meanwhile.
        guard isStarted, artworkKey == key else { return }
        onArtwork?(track, fetch.data)
    }

    /// https only (see `artworkURL(from:)`), capped at `maxArtworkBytes`.
    nonisolated static func downloadArtwork(from url: URL?, using session: URLSession) async -> ArtworkFetch {
        guard let url, url.scheme?.lowercased() == "https" else { return .none }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            // Ends the transfer on every early return; a no-op once it has completed.
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            guard (200..<300).contains(http.statusCode) else {
                return (400..<500).contains(http.statusCode) ? .none : .unavailable
            }
            let limit = NowPlayingConfig.maxArtworkBytes
            guard response.expectedContentLength <= Int64(limit) else { return .none }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            // Counting as it arrives stops an oversized or unannounced-length body at the cap.
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return .none }
            }
            return data.isEmpty ? .none : .image(data)
        } catch {
            return .unavailable
        }
    }

    // MARK: - Helpers

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    private func nextChange() -> Int {
        changeCounter += 1
        return changeCounter
    }

    private static func isRunning(_ player: Player) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).contains { !$0.isTerminated }
    }
}

// MARK: - Pure logic

extension NowPlayingMonitor {
    /// Whether a query may show the macOS Automation prompt: only one that follows something the
    /// user just did — playback starting in the player, or `refresh()`.
    enum PromptPolicy: Sendable {
        case mayPrompt, silent
    }

    /// A player's distributed notification, parsed.
    struct PlayerNotification: Equatable, Sendable {
        var player: Player
        /// nil when "Player State" is missing or unrecognized.
        var state: PlaybackState?
        /// nil when stopped, or when the notification lacks the track's ID.
        var track: Track?
    }

    struct PlayerRecord: Equatable, Sendable {
        var isRunning = false
        /// nil until a notification or query says.
        var state: PlaybackState?
        var track: Track?
        /// Order of the last reported change; the highest wins when both players play.
        var lastChange = 0
        /// Automation access was denied: not polled until its next notification or refresh().
        var isBlocked = false
        /// The track ID the last successful query returned.
        var confirmedTrackID: String?
        var artworkURL: URL?
        /// Identifies this record's lifetime; a query answer for an older one is dropped.
        var generation = 0

        /// Folds a notification in. Returns how to query the player next, or nil when the
        /// notification already said everything that's needed.
        mutating func apply(_ notification: PlayerNotification, change: Int) -> PromptPolicy? {
            lastChange = change
            guard let newState = notification.state else { return .silent }
            state = newState
            switch newState {
            case .stopped:
                track = nil
                return nil
            case .paused:
                if let newTrack = notification.track { track = newTrack }
                return nil
            case .playing:
                // Without an ID, nothing says the old track still plays.
                track = notification.track
                // The user just started playback: a prompt now is in context. Skipped when a query
                // already confirmed this track (a pause and resume) and access isn't in doubt.
                if let newTrack = notification.track, newTrack.id == confirmedTrackID, !isBlocked { return nil }
                return .mayPrompt
            }
        }

        mutating func apply(_ snapshot: PlayerSnapshot, change: Int) {
            if snapshot.state != state || snapshot.track != track { lastChange = change }
            isBlocked = false
            state = snapshot.state
            track = snapshot.track
            confirmedTrackID = snapshot.track?.id
            artworkURL = snapshot.artworkURL
        }
    }

    /// Parses "com.apple.Music.playerInfo" and "com.spotify.client.PlaybackStateChanged"; nil
    /// for any other notification.
    nonisolated static func parseNotification(name: String, userInfo: [AnyHashable: Any]) -> PlayerNotification? {
        let player: Player
        let id: String?
        switch name {
        case "com.apple.Music.playerInfo":
            player = .music
            id = musicID(fromNotificationValue: userInfo["PersistentID"])
        case "com.spotify.client.PlaybackStateChanged":
            player = .spotify
            id = userInfo["Track ID"] as? String
        default:
            return nil
        }
        let state: PlaybackState? = switch (userInfo["Player State"] as? String)?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: nil
        }
        var track: Track?
        if state != .stopped, let id, !id.isEmpty {
            track = Track(
                player: player,
                id: id,
                title: userInfo["Name"] as? String ?? "",
                artist: userInfo["Artist"] as? String ?? "",
                album: userInfo["Album"] as? String ?? ""
            )
        }
        return PlayerNotification(player: player, state: state, track: track)
    }

    /// Music's notification carries the persistent ID as a signed 64-bit number; AppleScript gives
    /// it as hex text. Both become the same canonical string.
    nonisolated static func musicID(fromNotificationValue value: Any?) -> String? {
        if let number = value as? NSNumber { return hex16(UInt64(bitPattern: number.int64Value)) }
        if let text = value as? String, !text.isEmpty { return canonicalMusicID(text) }
        return nil
    }

    /// 16 uppercase hex digits, zero-padded; anything that isn't hex is returned unchanged.
    nonisolated static func canonicalMusicID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = UInt64(trimmed, radix: 16) else { return trimmed }
        return hex16(value)
    }

    nonisolated private static func hex16(_ value: UInt64) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    /// Spotify's `artwork url`, if it's one we'll fetch: https only. Some Spotify versions report
    /// http:// addresses on their image CDN, which serves the same image over https, so http is
    /// upgraded rather than refused. Everything else (file:, data:, garbage) is refused.
    nonisolated static func artworkURL(from text: String) -> URL? {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": components.scheme = "https"
        default: return nil
        }
        return components.url
    }

    /// The status the records add up to. The most recently changed playing player wins; a denied
    /// player shows as `.notAuthorized` when it's that player, or when it's the only lead left
    /// (state unknown).
    nonisolated static func resolveStatus(isStarted: Bool, players: [Player: PlayerRecord]) -> Status {
        guard isStarted else { return .stopped }
        let running = players.filter(\.value.isRunning)
        guard !running.isEmpty else { return .noPlayer }
        // Newest change first; ties go to allCases order so the answer is deterministic.
        let ordered = running.sorted { a, b in
            if a.value.lastChange != b.value.lastChange { return a.value.lastChange > b.value.lastChange }
            return Player.allCases.firstIndex(of: a.key) ?? 0 < Player.allCases.firstIndex(of: b.key) ?? 0
        }
        if let (player, record) = ordered.first(where: { $0.value.state == .playing }) {
            if record.isBlocked { return .notAuthorized(player) }
            return .playing(record.track ?? Track(player: player, id: "", title: "", artist: "", album: ""))
        }
        if let (player, _) = ordered.first(where: { $0.value.isBlocked && $0.value.state == nil }) {
            return .notAuthorized(player)
        }
        return .notPlaying
    }
}

extension NowPlayingMonitor {
    struct ArtworkKey: Hashable, Sendable {
        var player: Player
        var id: String
    }

    /// Least-recently-used artwork results, including "this track has none".
    struct ArtworkCache {
        let capacity: Int
        /// Least recently used first.
        private(set) var entries: [(key: ArtworkKey, fetch: ArtworkFetch)] = []

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        /// The cached result for `key`, which becomes the most recently used; nil if not cached.
        mutating func lookup(_ key: ArtworkKey) -> ArtworkFetch? {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.fetch
        }

        mutating func store(_ fetch: ArtworkFetch, for key: ArtworkKey) {
            entries.removeAll { $0.key == key }
            entries.append((key, fetch))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }
}

/// Forwards the players' notifications and their launches and quits to the main actor.
///
/// A separate NSObject because only the selector-based distributed API takes a suspension
/// behavior: every other registration coalesces while the app is inactive, which for a menu-bar
/// app is nearly always, so notifications would sit undelivered.
@MainActor
private final class NowPlayingObserver: NSObject {
    private let onPlayerInfo: (NowPlayingMonitor.PlayerNotification) -> Void
    private let onLaunch: (NowPlayingMonitor.Player) -> Void
    private let onQuit: (NowPlayingMonitor.Player) -> Void

    init(
        onPlayerInfo: @escaping (NowPlayingMonitor.PlayerNotification) -> Void,
        onLaunch: @escaping (NowPlayingMonitor.Player) -> Void,
        onQuit: @escaping (NowPlayingMonitor.Player) -> Void
    ) {
        self.onPlayerInfo = onPlayerInfo
        self.onLaunch = onLaunch
        self.onQuit = onQuit
        super.init()
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            distributed.addObserver(
                self, selector: #selector(playerInfoChanged(_:)), name: Notification.Name(name),
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(applicationLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func invalidate() {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // Parsed where they arrive, since userInfo isn't Sendable; only the parsed value hops.
    @objc nonisolated private func playerInfoChanged(_ notification: Notification) {
        guard let event = NowPlayingMonitor.parseNotification(name: notification.name.rawValue, userInfo: notification.userInfo ?? [:]) else { return }
        Task { @MainActor [weak self] in self?.onPlayerInfo(event) }
    }

    @objc nonisolated private func applicationLaunched(_ notification: Notification) {
        guard let player = Self.player(in: notification) else { return }
        Task { @MainActor [weak self] in self?.onLaunch(player) }
    }

    @objc nonisolated private func applicationTerminated(_ notification: Notification) {
        guard let player = Self.player(in: notification) else { return }
        Task { @MainActor [weak self] in self?.onQuit(player) }
    }

    nonisolated private static func player(in notification: Notification) -> NowPlayingMonitor.Player? {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return NowPlayingMonitor.Player.allCases.first { $0.bundleIdentifier == application?.bundleIdentifier }
    }
}
