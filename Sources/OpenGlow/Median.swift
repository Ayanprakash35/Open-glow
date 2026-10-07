/// Exact medians by selection rather than sorting, with no allocation.
///
/// Quickselect around a median-of-three pivot, partitioning branch-free (Lomuto with a
/// conditional increment instead of a branch): on spectral data the comparisons are coin flips, so
/// a branching partition spends most of its time on mispredictions. Measured on 511 random
/// values, this is ≈3.5x faster than a branching Hoare quickselect and ≈10x faster than sorting.
/// The result is the same element a sort would put in the middle, so thresholds built on it don't
/// move.
enum Median {
    /// Median of `values`, which are reordered in the process. An even count averages the two
    /// middle values. NaNs can't trap or hang it; they just make the result meaningless.
    static func reordering(_ values: UnsafeMutableBufferPointer<Float>) -> Float {
        let n = values.count
        precondition(n > 0, "median of an empty buffer")
        let upper = n / 2
        let upperValue = select(values, k: upper)
        guard n % 2 == 0 else { return upperValue }
        // Selection leaves everything left of `upper` no larger, so the lower middle value is
        // their maximum.
        var lowerValue = values[0]
        for i in 1..<upper { lowerValue = max(lowerValue, values[i]) }
        return (lowerValue + upperValue) / 2
    }

    /// Moves the `k`th smallest value to index `k`, with no larger value before it and no smaller
    /// one after it, and returns it.
    ///
    /// Each pass keeps `k` inside `low..<high` and shrinks the range: the pivot is an element of
    /// it, so either some elements fall below the pivot, or the pass gathering the elements equal
    /// to it finds at least one. Only a NaN pivot finds none, and then it stops early.
    private static func select(_ values: UnsafeMutableBufferPointer<Float>, k: Int) -> Float {
        guard let a = values.baseAddress else { return 0 }
        var low = 0
        var high = values.count
        while high - low > 1 {
            let first = a[low], middle = a[low + (high - low) / 2], last = a[high - 1]
            let pivot = max(min(first, middle), min(max(first, middle), last))
            let below = partition(a, low..<high) { $0 < pivot }
            if k < below {
                high = below
            } else if below > low {
                low = below
            } else {
                // Nothing is below the pivot: it's the range's minimum. Gather its copies.
                let equalEnd = partition(a, low..<high) { $0 <= pivot }
                if k < equalEnd || equalEnd == low { return a[k] }
                low = equalEnd
            }
        }
        return a[k]
    }

    /// Moves the elements of `range` that satisfy `isLeft` to its front, without branching on
    /// the comparison, and returns where the rest begin.
    @inline(__always)
    private static func partition(_ a: UnsafeMutablePointer<Float>, _ range: Range<Int>, isLeft: (Float) -> Bool) -> Int {
        var store = range.lowerBound
        for i in range {
            let value = a[i]
            a[i] = a[store]
            a[store] = value
            store += isLeft(value) ? 1 : 0
        }
        return store
    }
}
