import Foundation
import os

/// Tuning for the artwork lookup.
enum ArtworkLookupConfig {
    /// Seconds allowed for the search and for the image download, each. Sane range: 3–15.
    static let timeout: TimeInterval = 8
    /// Largest cover accepted, in bytes.
    static let maximumBytes = 6_000_000
    /// Edge length, in pixels, requested from the store's image server (it scales on request).
    /// Extraction shrinks to 64×64 anyway, so bigger only costs bandwidth. Sane range: 100–600.
    static let imageSize = 300
    /// Search results considered when picking the matching album.
    static let resultLimit = 10
}

/// Finds a track's album cover through Apple's public iTunes Search API, for when the player won't
/// hand it over: Music gives scripts no artwork for streamed Apple Music tracks, and Spotify has
/// none for its local files. `ColorCoordinator` decides when it's asked.
///
/// What a lookup sends, over https with no cookies, to itunes.apple.com: a song search for
/// "artist title", then — only if that finds no confident match — an album search for
/// "artist album". Each search also carries the Mac's region as a two-letter country code, so
/// the user's own store is searched; it's left out when the region isn't one, and dropped for
/// the rest of the lookup if the store rejects it. The matching cover is then downloaded from the
/// address the store gave, on Apple's image server. Nothing else is sent.
enum ArtworkLookup {
    private static let logger = Logger(subsystem: "com.openglow.app", category: "ArtworkLookup")

    /// The cover's image data, or nil if no confident match was found. Searches by song first —
    /// artist plus title finds the track reliably and its result carries the album cover — then
    /// by album, which the store matches less reliably.
    static func artwork(artist: String, album: String, title: String) async -> Data? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let country = storeCountry(forRegion: Locale.current.region?.identifier)
        return await artwork(artist: artist, album: album, title: title, country: country, session: session)
    }

    /// `artwork(artist:album:title:)` with the store region and session given (internal for tests).
    static func artwork(artist: String, album: String, title: String, country: String?, session: URLSession) async -> Data? {
        guard !artist.isEmpty, !(album.isEmpty && title.isEmpty) else { return nil }
        var country = country
        var searched = 0
        for search in searches(artist: artist, album: album, title: title) {
            guard let results = await results(of: search, country: &country, session: session) else { continue }
            searched += results.count
            if let match = bestMatch(in: results, artist: artist, album: album, title: title),
               let coverURL = coverURL(from: match),
               let cover = await cover(from: coverURL, session: session) {
                return cover
            }
        }
        logger.notice("No confident artwork match in \(searched, privacy: .public) results")
        return nil
    }

    /// Runs one search. If the store rejects the country (HTTP 400: a region without an iTunes
    /// storefront), searches once more without it, and leaves it out of later searches too.
    private static func results(of search: Search, country: inout String?, session: URLSession) async -> [SearchResult]? {
        guard let url = searchURL(term: search.term, entity: search.entity, country: country) else { return nil }
        switch await results(from: url, session: session) {
        case .found(let results):
            return results
        case .rejected(status: 400) where country != nil:
            let rejected = country ?? ""
            logger.notice("The store rejected country \(rejected, privacy: .public); searching its default store instead")
            country = nil
            guard let url = searchURL(term: search.term, entity: search.entity, country: nil),
                  case .found(let results) = await results(from: url, session: session)
            else { return nil }
            return results
        case .rejected, .failed:
            return nil
        }
    }

    private enum SearchOutcome {
        case found([SearchResult])
        /// The store answered with this HTTP status instead of results.
        case rejected(status: Int)
        case failed
    }

    private static func results(from url: URL, session: URLSession) async -> SearchOutcome {
        do {
            var request = URLRequest(url: url, timeoutInterval: ArtworkLookupConfig.timeout)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                logger.notice("Artwork search answered HTTP \(status, privacy: .public)")
                return .rejected(status: status)
            }
            return .found(try JSONDecoder().decode(SearchResponse.self, from: data).results)
        } catch {
            logger.notice("Artwork search failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private static func cover(from url: URL, session: URLSession) async -> Data? {
        do {
            var request = URLRequest(url: url, timeoutInterval: ArtworkLookupConfig.timeout)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty, data.count <= ArtworkLookupConfig.maximumBytes
            else { return nil }
            return data
        } catch {
            logger.notice("Artwork download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pieces (internal for tests)

    struct SearchResponse: Decodable {
        var results: [SearchResult]
    }

    struct SearchResult: Decodable, Equatable {
        var artistName: String?
        var collectionName: String?
        var trackName: String?
        var artworkUrl100: String?
    }

    struct Search: Equatable {
        var term: String
        var entity: String
    }

    /// Song search first when there's a title, then album search when there's an album.
    static func searches(artist: String, album: String, title: String) -> [Search] {
        var searches: [Search] = []
        if !title.isEmpty { searches.append(Search(term: "\(artist) \(title)", entity: "song")) }
        if !album.isEmpty { searches.append(Search(term: "\(artist) \(album)", entity: "album")) }
        return searches
    }

    /// The store to search for a Mac region identifier: the region itself when it's a two-letter
    /// country code, else nil (the store's default, US). The store answers HTTP 400 to anything
    /// else, such as the UN M.49 areas "419" (Latin America) or "150" (Europe) that some
    /// locales carry.
    static func storeCountry(forRegion region: String?) -> String? {
        guard let scalars = region?.unicodeScalars, scalars.count == 2,
              scalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) })
        else { return nil }
        return region?.uppercased()
    }

    /// `country` nil leaves the parameter out.
    static func searchURL(term: String, entity: String, country: String?) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        var items = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(ArtworkLookupConfig.resultLimit)),
        ]
        // The user's own store, so regional releases are found.
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        components?.queryItems = items
        return components?.url
    }

    /// The result by the same artist that best matches the title and album. The artist must
    /// match, and so must the title or the album: a wrong cover would color the glow for the
    /// wrong song. Among equally good matches — editions whose qualifiers `normalized` drops,
    /// such as "(Deluxe Edition)" or "(Taylor's Version)" — the one spelled most exactly like the
    /// player's title and album wins, and only then the store's order.
    static func bestMatch(in results: [SearchResult], artist: String, album: String, title: String) -> SearchResult? {
        let wantedTitle = normalized(title)
        let wantedAlbum = normalized(album)
        func similarity(_ found: String?, _ wanted: String) -> Int {
            let found = normalized(found ?? "")
            guard !found.isEmpty, !wanted.isEmpty else { return 0 }
            if found == wanted { return 2 }
            return found.contains(wanted) || wanted.contains(found) ? 1 : 0
        }
        func exactness(_ found: String?, _ wanted: String) -> Int {
            let wanted = folded(wanted)
            return !wanted.isEmpty && folded(found ?? "") == wanted ? 1 : 0
        }
        var best: (result: SearchResult, score: Int, exactness: Int)?
        for result in results where isSameArtist(result.artistName ?? "", artist) {
            let score = 2 * similarity(result.trackName, wantedTitle) + similarity(result.collectionName, wantedAlbum)
            guard score > 0 else { continue }
            let exact = exactness(result.trackName, title) + exactness(result.collectionName, album)
            if let best, (score, exact) <= (best.score, best.exactness) { continue }
            best = (result, score, exact)
        }
        return best?.result
    }

    /// Whether two artist credits name the same artist: equal once normalized, or one is a run of
    /// whole words in the other ("Bon Iver" in "Bon Iver & Vince Staples", "Weeknd" in "The
    /// Weeknd") — never part of a word, so "X" doesn't match "Alex Turner".
    static func isSameArtist(_ found: String, _ wanted: String) -> Bool {
        let (a, b) = (normalized(found), normalized(wanted))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (foundWords, wantedWords) = (words(found), words(wanted))
        return containsRun(foundWords, in: wantedWords) || containsRun(wantedWords, in: foundWords)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func containsRun(_ run: [String], in words: [String]) -> Bool {
        guard !run.isEmpty, run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<$0 + run.count]) == run }
    }

    /// The cover at `imageSize`, from the result's 100×100 thumbnail address. https only.
    static func coverURL(from result: SearchResult) -> URL? {
        guard let thumbnail = result.artworkUrl100 else { return nil }
        let size = ArtworkLookupConfig.imageSize
        let resized = thumbnail.replacingOccurrences(of: "100x100", with: "\(size)x\(size)")
        guard var components = URLComponents(string: resized) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// Lowercased, without bracketed qualifiers ("(Deluxe Edition)", "[Remastered]"), release-type
    /// suffixes and punctuation, so the player's and the store's spellings compare equal.
    static func normalized(_ text: String) -> String {
        var value = text.lowercased()
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = value.range(of: open), let end = value.range(of: close, range: start.upperBound..<value.endIndex) {
                value.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        for suffix in [" - single", " - ep"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return folded(value)
    }

    /// Lowercased letters and digits only, qualifiers kept: compares spellings that differ only
    /// in case, spacing or punctuation (’ for ') as equal, but tells editions apart.
    static func folded(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
