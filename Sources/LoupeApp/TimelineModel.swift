import Foundation
import LoupeCore

/// Pure timeline geometry: request spans, lane packing, scrub lookups.
/// Separate from the view model so alignment is testable without SwiftUI.
enum TimelineGeometry {
    struct RequestSpan: Identifiable, Sendable, Equatable {
        let id: String
        let startSeconds: Double
        let prefillEndSeconds: Double
        let endSeconds: Double
        let lane: Int
    }

    /// Greedy lane packing: overlapping spans stack, sequential spans share
    /// lane 0. Spans must be sorted by start.
    static func packLanes(_ intervals: [(start: Double, end: Double)]) -> [Int] {
        var laneEnds: [Double] = []
        var assignment: [Int] = []
        for interval in intervals {
            if let free = laneEnds.firstIndex(where: { $0 <= interval.start }) {
                laneEnds[free] = interval.end
                assignment.append(free)
            } else {
                laneEnds.append(interval.end)
                assignment.append(laneEnds.count - 1)
            }
        }
        return assignment
    }

    static func requestSpans(
        metrics: [RequestMetrics], milestones: [ReplayViewModel.Milestone]
    ) -> [RequestSpan] {
        // Milestones carry offsets on the shared timeline; index them per
        // request so span edges come from the same clock as the charts.
        var startBy: [String: Double] = [:]
        var prefillBy: [String: Double] = [:]
        var endBy: [String: Double] = [:]
        for milestone in milestones {
            guard let requestId = milestone.requestId else { continue }
            switch milestone.kind {
            case .requestStart: startBy[requestId] = milestone.offsetSeconds
            case .prefillEnd: prefillBy[requestId] = milestone.offsetSeconds
            case .requestEnd: endBy[requestId] = milestone.offsetSeconds
            default: break
            }
        }
        let ordered = metrics.compactMap { metric -> (String, Double, Double, Double)? in
            guard let start = startBy[metric.requestId], let end = endBy[metric.requestId]
            else { return nil }
            return (metric.requestId, start, prefillBy[metric.requestId] ?? start, end)
        }
        .sorted { $0.1 < $1.1 }
        let lanes = packLanes(ordered.map { (start: $0.1, end: $0.3) })
        return zip(ordered, lanes).map { span, lane in
            RequestSpan(
                id: span.0, startSeconds: span.1, prefillEndSeconds: span.2,
                endSeconds: span.3, lane: lane)
        }
    }

    /// Nearest chart point at the scrub position.
    static func nearestIndex(in seconds: [Double], to target: Double) -> Int? {
        SortedSearch.nearestIndex(seconds, to: target)
    }

    static func activeSpan(in spans: [RequestSpan], at seconds: Double) -> RequestSpan? {
        spans.first { $0.startSeconds <= seconds && seconds <= $0.endSeconds }
    }
}
