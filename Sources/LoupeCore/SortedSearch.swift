/// The one binary search. Scrub lookups, annotation windows, and tick
/// counting all need "nearest sorted element"; two implementations of it had
/// already drifted on distance semantics before this existed.
public enum SortedSearch {
    /// First index whose key is >= value (== count when none).
    public static func lowerBound<Element, Key: Comparable>(
        _ sorted: [Element], value: Key, key: (Element) -> Key
    ) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if key(sorted[mid]) < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the element whose key is closest to value; exact ties
    /// resolve to the later element — the convention both pre-consolidation
    /// implementations shared. nil only for empty input.
    public static func nearestIndex<Element, Key: Comparable>(
        _ sorted: [Element], to value: Key, key: (Element) -> Key,
        distance: (Key, Key) -> Key
    ) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let bound = lowerBound(sorted, value: value, key: key)
        if bound == sorted.count { return sorted.count - 1 }
        if bound == 0 { return 0 }
        let left = key(sorted[bound - 1])
        let right = key(sorted[bound])
        return distance(value, left) < distance(right, value) ? bound - 1 : bound
    }

    public static func nearestIndex(_ sorted: [Double], to value: Double) -> Int? {
        nearestIndex(sorted, to: value, key: { $0 }, distance: { abs($0 - $1) })
    }
}
