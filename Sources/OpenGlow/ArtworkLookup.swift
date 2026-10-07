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
/// hand it over: Music.app gives scripts no artwork for streamed Apple Music tracks, only for
/// tracks stored in the library. Only the artist, album and title leave the Mac; nothing is sent
/// for a track whose artwork the player provided.
enum ArtworkLookup {
    private static let logger = Logger(subsystem: "com.openglow.app", category: "ArtworkLookup")

    /// The cover's image data, or nil if no confident match was found. Searches by song first —
    /// artist plus title finds the track reliably and its result carries the album cover — then
    /// by album, which the store matches less reliably.
    static func artwork(artist: String, album: String, title: String) async -> Data? {
        guard !artist.isEmpty, !(album.isEmpty && title.isEmpty) else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var searched = 0
        for search in searches(artist: artist, album: album, title: title) {
            guard let url = searchURL(term: search.term, entity: search.entity),
                  let results = await results(from: url, session: session)
            else { continue }
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

    private static func results(from url: URL, session: URLSession) async -> [SearchResult]? {
        do {
            var request = URLRequest(url: url, timeoutInterval: ArtworkLookupConfig.timeout)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(SearchResponse.self, from: data).results
        } catch {
            logger.notice("Artwork search failed: \(error.localizedDescription, privacy: .public)")
            return nil
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

    static func searchURL(term: String, entity: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(ArtworkLookupConfig.resultLimit)),
            // The user's own store, so regional releases are found.
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        return components?.url
    }

    /// The result by the same artist that best matches the title and album. The artist must
    /// match, and so must the title or the album: a wrong cover would color the glow for the
    /// wrong song.
    static func bestMatch(in results: [SearchResult], artist: String, album: String, title: String) -> SearchResult? {
        let wantedArtist = normalized(artist)
        let wantedTitle = normalized(title)
        let wantedAlbum = normalized(album)
        func similarity(_ found: String?, _ wanted: String) -> Int {
            let found = normalized(found ?? "")
            guard !found.isEmpty, !wanted.isEmpty else { return 0 }
            if found == wanted { return 2 }
            return found.contains(wanted) || wanted.contains(found) ? 1 : 0
        }
        var best: (result: SearchResult, score: Int)?
        for result in results {
            guard similarity(result.artistName, wantedArtist) > 0 else { continue }
            let score = 2 * similarity(result.trackName, wantedTitle) + similarity(result.collectionName, wantedAlbum)
            if score > 0, score > (best?.score ?? 0) { best = (result, score) }
        }
        return best?.result
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
        return String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
