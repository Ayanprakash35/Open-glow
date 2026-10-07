import Foundation
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
        let url = try #require(ArtworkLookup.searchURL(term: "Malcolm Todd Earrings", entity: "song"))
        #expect(url.scheme == "https" && url.host == "itunes.apple.com")
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
