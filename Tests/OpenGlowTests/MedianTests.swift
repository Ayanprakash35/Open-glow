import Testing
@testable import OpenGlow

/// Deterministic values with plenty of exact duplicates, as quantized or floored spectra produce.
private struct ValueGenerator {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let raw = Float(state >> 40) / Float(1 << 24) * 2 - 1
        return state % 4 == 0 ? (raw * 4).rounded() / 4 : raw
    }
}

private func sortedMedian(_ values: [Float]) -> Float {
    let sorted = values.sorted()
    let n = sorted.count
    return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

@Suite("Medians")
struct MedianTests {
    @Test func selectionMatchesSorting() {
        var generator = ValueGenerator(state: 3)
        for n in Array(1...40) + [85, 93, 128, 511, 512] {
            for round in 0..<20 {
                var values = (0..<n).map { _ in generator.next() }
                if round == 1 { values.sort() }
                if round == 2 { values = values.sorted().reversed() }
                if round == 3 { values = [Float](repeating: values[0], count: n) }
                let expected = sortedMedian(values)
                let median = values.withUnsafeMutableBufferPointer { Median.reordering($0) }
                #expect(median == expected, "n \(n), round \(round)")
            }
        }
    }

    @Test func nanDoesNotHang() {
        for values: [Float] in [[.nan, 1, 2, .nan, 0], [.nan, .nan, .nan], [3, .nan, 1, 2], [1, 2, 3, 4, .nan, 0, -1, .nan]] {
            var copy = values
            _ = copy.withUnsafeMutableBufferPointer { Median.reordering($0) }
        }
    }

    /// The incrementally sorted history gives exactly the median a sort of the last `capacity`
    /// values gives, before and after a clear.
    @Test func onsetTrackMedianMatchesSortingTheHistory() {
        var generator = ValueGenerator(state: 11)
        let capacity = 93
        var track = OnsetTrack(capacity: capacity, margin: 0.1)
        var history: [Float] = []
        for step in 0..<1_000 {
            if step == 400 {
                track.clear()
                history.removeAll()
            }
            let expected: Float? = history.count >= 8 ? sortedMedian(Array(history.suffix(capacity))) : nil
            #expect(track.median() == expected, "step \(step)")
            let value = generator.next()
            track.append(value)
            history.append(value)
        }
    }
}
