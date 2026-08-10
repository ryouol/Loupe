import Foundation
import LoupeCore

public struct BenchmarkReport: Codable, Sendable, Equatable {
    public struct ContextResult: Codable, Sendable, Equatable {
        public let contextTokens: Int
        /// Post-warmup runs only; warmup is discarded before assembly.
        public let runs: [RunResult]
        public let ttftMs: DistributionSummary
        public let decodeTokensPerSecond: DistributionSummary
    }

    public struct RunResult: Codable, Sendable, Equatable {
        public let runIndex: Int
        public let requests: [RequestMetrics]
    }

    public let formatVersion: Int
    public let spec: BenchmarkSpec
    public let host: HostFingerprint
    public let createdAtNs: UInt64
    public let contexts: [ContextResult]
}

public enum BenchmarkAssembler {
    public static let formatVersion = 1

    /// Pure assembly: measured event streams in, stable report out. The
    /// golden-file test pins this structure.
    public static func report(
        spec: BenchmarkSpec,
        host: HostFingerprint,
        createdAtNs: UInt64,
        measuredRunsByContext: [Int: [[EventEnvelope]]]
    ) -> BenchmarkReport {
        let contexts = measuredRunsByContext.keys.sorted().map { context in
            let runs = (measuredRunsByContext[context] ?? []).enumerated().map { index, events in
                BenchmarkReport.RunResult(
                    runIndex: index, requests: SessionMetrics.perRequest(events: events))
            }
            let allRequests = runs.flatMap(\.requests)
            return BenchmarkReport.ContextResult(
                contextTokens: context,
                runs: runs,
                ttftMs: DistributionSummary(values: allRequests.map(\.ttftMs)),
                decodeTokensPerSecond: DistributionSummary(
                    values: allRequests.map(\.decodeTokensPerSecond)))
        }
        return BenchmarkReport(
            formatVersion: formatVersion,
            spec: spec,
            host: host,
            createdAtNs: createdAtNs,
            contexts: contexts)
    }

    public static func encode(_ report: BenchmarkReport) throws -> Data {
        try JSONEncoder.deterministic().encode(report)
    }

    public static func decode(_ data: Data) throws -> BenchmarkReport {
        try JSONDecoder().decode(BenchmarkReport.self, from: data)
    }
}
