import Foundation

/// A loss count whose exact value may be unavailable at a process boundary.
/// `lowerBound` is always observable evidence; `exact` is present only after
/// the producer delivered a terminal summary that closed the accounting
/// window. Legacy recordings intentionally decode to `nil`, not a fabricated
/// zero.
public struct AcquisitionLossCount: Codable, Sendable, Equatable {
    /// Fixed labels keep imported metadata bounded and prevent arbitrary text
    /// from becoming a new evidence-export channel.
    public static let allowedBreakdownKeys: Set<String> = [
        "producer_reported", "producer_sequence_gap_lower_bound",
        "sequence_integrity_violations", "socket_parser", "event_buffer",
        "ingest_chunk_lower_bound", "connection_commands", "status_notifications",
        "recording_validation", "recording_limit", "recording_persistence",
        "known_dropped_samples", "sequence_gap_lower_bound", "malformed_samples",
    ]

    public let exact: Int?
    public let lowerBound: Int
    public let breakdown: [String: Int]

    public init(exact: Int?, lowerBound: Int, breakdown: [String: Int]) {
        self.exact = exact
        self.lowerBound = lowerBound
        self.breakdown = breakdown
    }

    public static let unknown = AcquisitionLossCount(
        exact: nil, lowerBound: 0, breakdown: [:])

    public var isValid: Bool {
        lowerBound >= 0
            && (exact.map { $0 >= lowerBound } ?? true)
            && breakdown.count <= Self.allowedBreakdownKeys.count
            && breakdown.allSatisfy {
                Self.allowedBreakdownKeys.contains($0.key) && $0.value >= 0
            }
    }
}

/// Durable recording-time acquisition integrity. Replay parser corruption is
/// deliberately not stored here: it is recomputed from the exact portable
/// bytes on every load and reported separately.
public struct SessionAcquisitionMetadata: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let eventLosses: AcquisitionLossCount
    public let telemetryLosses: AcquisitionLossCount

    public init(
        eventLosses: AcquisitionLossCount,
        telemetryLosses: AcquisitionLossCount
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.eventLosses = eventLosses
        self.telemetryLosses = telemetryLosses
    }

    public static let unknown = SessionAcquisitionMetadata(
        eventLosses: .unknown, telemetryLosses: .unknown)

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && eventLosses.isValid && telemetryLosses.isValid
    }
}

/// Runtime telemetry accounting shared by in-process streams and the XPC
/// boundary. `complete` becomes true only when the source's terminal summary
/// was observed; sequence gaps still provide a useful lower bound otherwise.
public struct TelemetryAcquisitionStats: Codable, Sendable, Equatable {
    public let droppedSamples: Int
    public let sequenceGapLowerBound: Int
    public let malformedSamples: Int
    public let complete: Bool
    public let sourceWasActive: Bool

    public init(
        droppedSamples: Int = 0,
        sequenceGapLowerBound: Int = 0,
        malformedSamples: Int = 0,
        complete: Bool,
        sourceWasActive: Bool = true
    ) {
        self.droppedSamples = droppedSamples
        self.sequenceGapLowerBound = sequenceGapLowerBound
        self.malformedSamples = malformedSamples
        self.complete = complete
        self.sourceWasActive = sourceWasActive
    }

    public static let unknown = TelemetryAcquisitionStats(
        complete: false, sourceWasActive: false)

    public var lowerBound: Int {
        // Stream drops and malformed deliveries are distinct observations,
        // while a later sequence gap may describe either or both. Compare
        // the gap with their sum instead of adding it and double-counting the
        // same missing sample.
        max(Self.saturatingSum(droppedSamples, malformedSamples), sequenceGapLowerBound)
    }

    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
    }
}
