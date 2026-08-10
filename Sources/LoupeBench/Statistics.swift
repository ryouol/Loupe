/// Distribution summary for run-to-run comparison. Never a bare mean: the
/// spec requires percentiles and spread, because inference latency is
/// long-tailed and a mean alone hides throttling.
public struct DistributionSummary: Codable, Sendable, Equatable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let mean: Double
    public let stddev: Double
    public let min: Double
    public let max: Double

    public init(values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        guard !sorted.isEmpty else {
            p50 = 0
            p95 = 0
            mean = 0
            stddev = 0
            min = 0
            max = 0
            return
        }
        p50 = Self.nearestRank(sorted, percentile: 50)
        p95 = Self.nearestRank(sorted, percentile: 95)
        let total = sorted.reduce(0, +)
        mean = total / Double(sorted.count)
        min = sorted[0]
        max = sorted[sorted.count - 1]
        if sorted.count > 1 {
            let meanValue = mean
            let sumOfSquares = sorted.reduce(0) { $0 + ($1 - meanValue) * ($1 - meanValue) }
            stddev = (sumOfSquares / Double(sorted.count - 1)).squareRoot()
        } else {
            stddev = 0
        }
    }

    private static func nearestRank(_ sorted: [Double], percentile: Double) -> Double {
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
    }
}
