/// Largest-Triangle-Three-Buckets: the downsampling that keeps charts honest.
/// Uniform decimation erases exactly the spikes a profiler exists to show;
/// LTTB keeps the visually dominant point of every bucket and both endpoints.
public enum Downsample {
    public static func lttb<T>(
        _ points: [T], to threshold: Int, x: (T) -> Double, y: (T) -> Double
    ) -> [T] {
        guard threshold >= 3, points.count > threshold else { return points }

        var sampled: [T] = []
        sampled.reserveCapacity(threshold)
        sampled.append(points[0])

        let bucketSize = Double(points.count - 2) / Double(threshold - 2)
        var previousIndex = 0

        for bucket in 0..<(threshold - 2) {
            let rangeStart = Int(Double(bucket) * bucketSize) + 1
            let rangeEnd = min(Int(Double(bucket + 1) * bucketSize) + 1, points.count - 1)

            // The next bucket's average anchors the triangle's third corner.
            let nextStart = rangeEnd
            let nextEnd = min(Int(Double(bucket + 2) * bucketSize) + 1, points.count)
            var averageX = 0.0
            var averageY = 0.0
            let nextCount = max(1, nextEnd - nextStart)
            for index in nextStart..<max(nextStart + 1, nextEnd) {
                let clamped = min(index, points.count - 1)
                averageX += x(points[clamped])
                averageY += y(points[clamped])
            }
            averageX /= Double(nextCount)
            averageY /= Double(nextCount)

            let anchorX = x(points[previousIndex])
            let anchorY = y(points[previousIndex])

            var bestIndex = rangeStart
            var bestArea = -1.0
            for index in rangeStart..<max(rangeStart + 1, rangeEnd) {
                let area = abs(
                    (anchorX - averageX) * (y(points[index]) - anchorY)
                        - (anchorX - x(points[index])) * (averageY - anchorY))
                if area > bestArea {
                    bestArea = area
                    bestIndex = index
                }
            }
            sampled.append(points[bestIndex])
            previousIndex = bestIndex
        }

        sampled.append(points[points.count - 1])
        return sampled
    }
}
