/// Per-request latency/throughput derived purely from the event stream —
/// shared by the benchmark harness, the results view, and annotation rules.
public struct RequestMetrics: Codable, Sendable, Equatable, Identifiable {
    public var id: String { requestId }
    public let requestId: String
    public let promptTokens: Int
    public let outputTokens: Int
    public let ttftNs: UInt64
    public let decodeDurationNs: UInt64

    public var ttftMs: Double { Double(ttftNs) / 1e6 }
    /// Tokens over the decode window (prefill_end → request_end).
    public var decodeTokensPerSecond: Double {
        guard decodeDurationNs > 0 else { return 0 }
        return Double(outputTokens) / (Double(decodeDurationNs) / 1e9)
    }

    public init(
        requestId: String, promptTokens: Int, outputTokens: Int,
        ttftNs: UInt64, decodeDurationNs: UInt64
    ) {
        self.requestId = requestId
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.ttftNs = ttftNs
        self.decodeDurationNs = decodeDurationNs
    }
}

public enum SessionMetrics {
    /// One entry per request that completed the full start → prefill → end
    /// arc; partial requests (errors, cancellations mid-prefill) are skipped
    /// rather than reported with invented numbers.
    public static func perRequest(events: [EventEnvelope]) -> [RequestMetrics] {
        struct Partial {
            var startTs: UInt64?
            var prefillTs: UInt64?
            var promptTokens = 0
            var endTs: UInt64?
            var outputTokens = 0
            var order: Int
        }
        var partials: [String: Partial] = [:]
        var order = 0

        for envelope in events {
            guard let requestId = envelope.requestId else { continue }
            switch envelope.payload {
            case .requestStart:
                partials[requestId, default: Partial(order: order)].startTs = envelope.ts
                partials[requestId]?.order = order
                order += 1
            case .prefillEnd(let payload):
                partials[requestId, default: Partial(order: order)].prefillTs = envelope.ts
                partials[requestId]?.promptTokens = Int(payload.promptTokens)
            case .requestEnd(let payload):
                partials[requestId, default: Partial(order: order)].endTs = envelope.ts
                partials[requestId]?.outputTokens = Int(payload.outputTokens)
            default:
                break
            }
        }

        return
            partials
            .compactMap { requestId, partial -> (Int, RequestMetrics)? in
                guard let start = partial.startTs, let prefill = partial.prefillTs,
                    let end = partial.endTs, prefill >= start, end >= prefill
                else { return nil }
                return (
                    partial.order,
                    RequestMetrics(
                        requestId: requestId,
                        promptTokens: partial.promptTokens,
                        outputTokens: partial.outputTokens,
                        ttftNs: prefill - start,
                        decodeDurationNs: end - prefill)
                )
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}
