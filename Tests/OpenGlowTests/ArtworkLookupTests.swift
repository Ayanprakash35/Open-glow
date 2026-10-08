import Foundation
import os
import Testing
@testable import OpenGlow

@Suite("Artwork lookup")
struct ArtworkLookupTests {
    private func result(_ artist: String, _ album: String, art: String = "https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg") -> ArtworkLookup.SearchResult {
        ArtworkLookup.SearchResult(artistName: artist, collectionName: album, trackName: nil, artworkUrl100: art)
    }

    @Test func searchesBySongFirstThenByAlbum() throws {
        let searches = ArtworkLookup.searches(artist: "Malcolm Todd", album: "Sweet Boy", title: "Earrings")
        #expect(searches == [
            .init(term: "Malcolm Todd Earrings", entity: "song"),
            .init(term: "Malcolm Todd Sweet Boy", entity: "album"),
        ])
        #expect(ArtworkLookup.searches(artist: "A", album: "", title: "T").count == 1)
        let url = try #require(ArtworkLookup.searchURL(term: "Malcolm Todd Earrings", entity: "song", country: "IN"))
        #expect(url.scheme == "https" && url.host == "itunes.apple.com")
        #expect(queryItems(url)["country"] == "IN")
        let noCountry = try #require(ArtworkLookup.searchURL(term: "Malcolm Todd Earrings", entity: "song", country: nil))
        #expect(queryItems(noCountry)["country"] == nil)
        #expect(queryItems(noCountry)["term"] == "Malcolm Todd Earrings")
    }

    /// Only a two-letter region is sent as the store's country: the store rejects the UN M.49
    /// areas some locales carry (en_150, es_419, en_001) with HTTP 400.
    @Test func sendsOnlyTwoLetterRegionsAsTheCountry() {
        #expect(ArtworkLookup.storeCountry(forRegion: "US") == "US")
        #expect(ArtworkLookup.storeCountry(forRegion: "gb") == "GB")
        #expect(ArtworkLookup.storeCountry(forRegion: "150") == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: "419") == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: "001") == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: "USA") == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: "É") == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: "") == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: nil) == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: Locale(identifier: "es_419").region?.identifier) == nil)
        #expect(ArtworkLookup.storeCountry(forRegion: Locale(identifier: "en_IN").region?.identifier) == "IN")
    }

    @Test func picksTheSameArtistsMatchingSong() {
        let results = [
            ArtworkLookup.SearchResult(artistName: "sodepressed", collectionName: "Earrings (Cover) - Single", trackName: "Earrings (Sped Up)", artworkUrl100: "x"),
            ArtworkLookup.SearchResult(artistName: "Malcolm Todd", collectionName: "Sweet Boy", trackName: "Accutane", artworkUrl100: "x"),
            ArtworkLookup.SearchResult(artistName: "Malcolm Todd", collectionName: "Sweet Boy", trackName: "Earrings", artworkUrl100: "x"),
        ]
        #expect(ArtworkLookup.bestMatch(in: results, artist: "Malcolm Todd", album: "Sweet Boy", title: "Earrings") == results[2])
    }

    @Test func picksTheSameArtistsMatchingAlbum() {
        let results = [
            result("Someone Else", "Earrings"),
            result("Malcolm Todd", "Sweet Boy (Deluxe)"),
            result("Malcolm Todd", "Earrings - Single"),
        ]
        #expect(ArtworkLookup.bestMatch(in: results, artist: "Malcolm Todd", album: "Earrings", title: "") == results[2])
        #expect(ArtworkLookup.bestMatch(in: results, artist: "Malcolm Todd", album: "Sweet Boy", title: "") == results[1])
    }

    @Test func refusesOtherArtistsCovers() {
        let results = [result("Someone Else", "Earrings")]
        #expect(ArtworkLookup.bestMatch(in: results, artist: "Malcolm Todd", album: "Earrings", title: "Earrings") == nil)
    }

    /// The store lists the original first; the qualifiers that tell the editions apart are
    /// dropped by `normalized`, so the exact spelling decides.
    @Test func prefersTheExactEdition() {
        let original = ArtworkLookup.SearchResult(artistName: "Taylor Swift", collectionName: "1989", trackName: "Style", artworkUrl100: "a")
        let taylorsVersion = ArtworkLookup.SearchResult(
            artistName: "Taylor Swift", collectionName: "1989 (Taylor's Version)", trackName: "Style (Taylor's Version)", artworkUrl100: "b"
        )
        let results = [original, taylorsVersion]
        // The player spells it with a curly apostrophe, the store with a straight one.
        #expect(ArtworkLookup.bestMatch(in: results, artist: "Taylor Swift", album: "1989 (Taylor’s Version)", title: "Style (Taylor’s Version)") == taylorsVersion)
        #expect(ArtworkLookup.bestMatch(in: [taylorsVersion, original], artist: "Taylor Swift", album: "1989", title: "Style") == original)

        let standard = result("Band", "Album")
        let deluxe = result("Band", "Album (Deluxe Edition)")
        #expect(ArtworkLookup.bestMatch(in: [standard, deluxe], artist: "Band", album: "Album (Deluxe Edition)", title: "") == deluxe)
        #expect(ArtworkLookup.bestMatch(in: [deluxe, standard], artist: "Band", album: "Album", title: "") == standard)
    }

    /// A short artist name inside a longer one is a different artist, not a match.
    @Test func matchesArtistsByWholeWords() {
        let x = ArtworkLookup.SearchResult(artistName: "X", collectionName: "Love", trackName: "Love", artworkUrl100: "x")
        #expect(ArtworkLookup.bestMatch(in: [x], artist: "Alex Turner", album: "", title: "Love") == nil)
        #expect(!ArtworkLookup.isSameArtist("X", "Alex Turner"))
        #expect(!ArtworkLookup.isSameArtist("Turn", "Alex Turner"))
        #expect(ArtworkLookup.isSameArtist("Bon Iver", "Bon Iver & Vince Staples"))
        #expect(ArtworkLookup.isSameArtist("The Weeknd", "Weeknd"))
        #expect(ArtworkLookup.isSameArtist("AC/DC", "ACDC"))
        #expect(ArtworkLookup.isSameArtist("Jay-Z", "JAY Z"))
        #expect(!ArtworkLookup.isSameArtist("", "Anyone"))
    }

    @Test func asksForALargerHTTPSCover() {
        let url = ArtworkLookup.coverURL(from: result("A", "B", art: "http://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg"))
        #expect(url?.scheme == "https")
        #expect(url?.absoluteString.contains("\(ArtworkLookupConfig.imageSize)x\(ArtworkLookupConfig.imageSize)bb") == true)
    }

    @Test func normalizesQualifiersAndPunctuation() {
        #expect(ArtworkLookup.normalized("Sweet Boy (Deluxe Edition) [Remastered]") == "sweetboy")
        #expect(ArtworkLookup.normalized("Earrings - Single") == "earrings")
        #expect(ArtworkLookup.normalized("AC/DC") == "acdc")
    }
}

private func queryItems(_ url: URL?) -> [String: String] {
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

/// Answers the lookup without the network, the way the store answers a country it has no
/// storefront for: HTTP 400 to any search naming a country, one matching song otherwise, and a
/// few bytes for the cover. Records every request.
private final class RegionlessStore: URLProtocol {
    static let requests = OSAllocatedUnfairLock<[URL]>(initialState: [])
    static let cover = Data([0xFF, 0xD8, 0xFF])
    private static let rejection = Data(#"{"errorMessage":"Invalid value(s) for key(s): [country]"}"#.utf8)
    private static let song = Data(#"{"resultCount":1,"results":[{"artistName":"Malcolm Todd","collectionName":"Sweet Boy","trackName":"Earrings","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg"}]}"#.utf8)

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegionlessStore.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0.append(url) }
        let namesCountry = queryItems(url)["country"] != nil
        let (status, body): (Int, Data) = switch url.host {
        case "itunes.apple.com": namesCountry ? (400, Self.rejection) : (200, Self.song)
        default: (200, Self.cover)
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Artwork lookup: a region the store rejects")
struct ArtworkLookupRegionTests {
    /// Iran has no iTunes storefront, so the store answers HTTP 400; the lookup still finds the
    /// cover in the default store, with one extra request.
    @Test func retriesOnceWithoutTheCountry() async throws {
        let session = RegionlessStore.makeSession()
        defer { session.invalidateAndCancel() }
        let cover = await ArtworkLookup.artwork(artist: "Malcolm Todd", album: "Sweet Boy", title: "Earrings", country: "IR", session: session)
        #expect(cover == RegionlessStore.cover)
        let requests = RegionlessStore.requests.withLock { $0 }
        try #require(requests.count == 3)
        #expect(queryItems(requests[0])["country"] == "IR")
        #expect(queryItems(requests[1])["country"] == nil, "the same search again, without the country")
        #expect(queryItems(requests[1])["term"] == "Malcolm Todd Earrings")
        #expect(requests[2].host == "is1-ssl.mzstatic.com")
    }
}

/// Talks to the real iTunes Search API, so it only runs when OPENGLOW_NETWORK_TESTS is set.
@Suite("Artwork lookup (network)")
struct ArtworkLookupNetworkTests {
    nonisolated private static let enabled = ProcessInfo.processInfo.environment["OPENGLOW_NETWORK_TESTS"] != nil

    @Test(.enabled(if: enabled))
    func findsARealCoverAndItsColors() async throws {
        let cover = try #require(await ArtworkLookup.artwork(artist: "Malcolm Todd", album: "Sweet Boy", title: "Earrings"))
        let result = try #require(ColorExtractor.extract(fromImageData: cover))
        print("cover \(cover.count) bytes → \(result.source), primary \(result.palette.primary), secondary \(result.palette.secondary), balance \(result.palette.balance)")
        #expect(result.source != .fallback)
    }

    /// Iran has no iTunes storefront: the real store answers HTTP 400, and the lookup still finds
    /// the cover in its default store.
    @Test(.enabled(if: enabled))
    func findsACoverWhenTheStoreRejectsTheRegion() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let cover = await ArtworkLookup.artwork(artist: "Malcolm Todd", album: "Sweet Boy", title: "Earrings", country: "IR", session: session)
        #expect(cover != nil)
    }
}

/// Looks up any track given as OPENGLOW_LOOKUP="artist|album|title" and prints what the glow would
/// use, with timings — for checking a specific album by hand.
@Suite("Artwork lookup (manual)")
struct ArtworkLookupManualTests {
    nonisolated private static let request = ProcessInfo.processInfo.environment["OPENGLOW_LOOKUP"]

    @Test(.enabled(if: request != nil))
    func lookUpRequestedTrack() async throws {
        let parts = (Self.request ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        try #require(parts.count == 3)
        let started = Date()
        let cover = await ArtworkLookup.artwork(artist: parts[0], album: parts[1], title: parts[2])
        let lookupTime = Date().timeIntervalSince(started)
        guard let cover else {
            print("lookup: no cover (\(Int(lookupTime * 1000)) ms)")
            return
        }
        let extractStart = Date()
        let result = ColorExtractor.extract(fromImageData: cover)
        print("lookup \(Int(lookupTime * 1000)) ms, \(cover.count) bytes; extract \(Int(Date().timeIntervalSince(extractStart) * 1000)) ms → \(String(describing: result?.source)) \(String(describing: result?.palette))")
    }
}
