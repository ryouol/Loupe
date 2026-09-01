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
    /// Tokens over the full prefill-end → request-end generation window,
    /// including the first generated token. Protocol-v2+ adapters report this
    /// interval directly; legacy recordings fall back to event timestamps.
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
    /// One entry per request that completed the full start → prefill → first
    /// output → end arc. Partial or zero-output requests are skipped rather
    /// than reported with invented TTFT values.
    public static func perRequest(events: [EventEnvelope]) -> [RequestMetrics] {
        struct Partial {
            var startTs: UInt64?
            var prefillTs: UInt64?
            var firstOutputTs: UInt64?
            var promptTokens = 0
            var endTs: UInt64?
            var outputTokens = 0
            var runtimeDecodeDurationNs: UInt64?
            var protocolVersion = EventProtocol.legacyVersion
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
                partials[requestId]?.protocolVersion = envelope.v
                order += 1
            case .prefillEnd(let payload):
                partials[requestId, default: Partial(order: order)].prefillTs = envelope.ts
                partials[requestId]?.promptTokens = Int(payload.promptTokens)
            case .decodeTick(let payload):
                if payload.outputTokens > 0, partials[requestId]?.firstOutputTs == nil {
                    partials[requestId, default: Partial(order: order)].firstOutputTs = envelope.ts
                }
            case .requestEnd(let payload):
                partials[requestId, default: Partial(order: order)].endTs = envelope.ts
                partials[requestId]?.outputTokens = Int(payload.outputTokens)
                partials[requestId]?.runtimeDecodeDurationNs = payload.decodeDurationNs
            default:
                break
            }
        }

        return
            partials
            .compactMap { requestId, partial -> (Int, RequestMetrics)? in
                guard let start = partial.startTs, let prefill = partial.prefillTs,
                    let firstOutput = partial.firstOutputTs, let end = partial.endTs,
                    prefill >= start, firstOutput >= prefill, end >= firstOutput
                else { return nil }
                let decodeDuration: UInt64
                if let measured = partial.runtimeDecodeDurationNs {
                    decodeDuration = measured
                } else if partial.protocolVersion == EventProtocol.legacyVersion {
                    decodeDuration = end - prefill
                } else if partial.outputTokens == 0 {
                    decodeDuration = 0
                } else {
                    // A sequenced adapter that cannot establish the first-token
                    // boundary must not silently publish a partial-window
                    // throughput number.
                    return nil
                }
                return (
                    partial.order,
                    RequestMetrics(
                        requestId: requestId,
                        promptTokens: partial.promptTokens,
                        outputTokens: partial.outputTokens,
                        ttftNs: firstOutput - start,
                        decodeDurationNs: decodeDuration)
                )
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}
