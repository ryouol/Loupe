import Foundation
import LoupeBench
import LoupeCore
import Observation

@MainActor
@Observable
public final class ResultsViewModel {
    public enum LatencySemantics: Sendable, Equatable {
        /// Report v3: request start to the first positive output tick.
        case firstOutputTTFT
        /// Historical report v1/v2: request start to prefill end.
        case legacyPrefillEnd
        /// A future/unsupported report version whose stored field is view-only.
        case unknown
    }

    public struct SweepPoint: Identifiable, Sendable {
        public var id: Int { contextTokens }
        public let contextTokens: Int
        public let decode: DistributionSummary
        public let ttft: DistributionSummary
    }

    public struct RunRow: Identifiable, Sendable {
        public let id: String
        public let contextTokens: Int
        public let runIndex: Int
        public let ttftMs: Double
        public let decodeTokensPerSecond: Double
        public let outputTokens: Int
    }

    public private(set) var report: BenchmarkReport?
    public private(set) var reportName: String = ""
    public private(set) var sweep: [SweepPoint] = []
    public private(set) var runRows: [RunRow] = []
    public private(set) var loadFailure: String?

    public var latencySemantics: LatencySemantics {
        guard let formatVersion = report?.formatVersion else { return .unknown }
        switch formatVersion {
        case BenchmarkAssembler.formatVersion: return .firstOutputTTFT
        case 1, 2: return .legacyPrefillEnd
        default: return .unknown
        }
    }

    public var latencyChartTitle: String {
        switch latencySemantics {
        case .firstOutputTTFT: return "Time to First Token vs Context"
        case .legacyPrefillEnd: return "Legacy Prefill-End Latency vs Context"
        case .unknown: return "Stored Latency Metric vs Context"
        }
    }

    public var latencyAxisTitle: String {
        switch latencySemantics {
        case .firstOutputTTFT: return "TTFT ms (p50 ± σ)"
        case .legacyPrefillEnd: return "prefill-end latency ms (p50 ± σ)"
        case .unknown: return "stored latency ms (p50 ± σ)"
        }
    }

    public var latencyColumnTitle: String {
        switch latencySemantics {
        case .firstOutputTTFT: return "TTFT"
        case .legacyPrefillEnd: return "Prefill end"
        case .unknown: return "Latency"
        }
    }

    public init() {}

    public func load(url: URL) {
        do {
            let decoded = try BenchmarkAssembler.decode(contentsOf: url)
            report = decoded
            reportName = url.deletingPathExtension().lastPathComponent
            sweep = decoded.contexts.map {
                SweepPoint(
                    contextTokens: $0.contextTokens,
                    decode: $0.decodeTokensPerSecond,
                    ttft: $0.ttftMs)
            }
            runRows = decoded.contexts.flatMap { context in
                context.runs.map { run in
                    let requests = run.requests
                    let ttft = requests.map(\.ttftMs).reduce(0, +) / Double(max(1, requests.count))
                    let rate =
                        requests.map(\.decodeTokensPerSecond).reduce(0, +)
                        / Double(max(1, requests.count))
                    return RunRow(
                        id: "\(context.contextTokens)-\(run.runIndex)",
                        contextTokens: context.contextTokens,
                        runIndex: run.runIndex,
                        ttftMs: ttft,
                        decodeTokensPerSecond: rate,
                        outputTokens: requests.reduce(0) { $0 + $1.outputTokens })
                }
            }
            loadFailure = nil
        } catch {
            report = nil
            sweep = []
            runRows = []
            loadFailure = "Cannot read report: \(error.localizedDescription)"
        }
    }
}
