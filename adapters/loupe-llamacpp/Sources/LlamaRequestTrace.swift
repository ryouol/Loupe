import Foundation
import LoupeCore

/// Maps one streamed `/completion` exchange onto current protocol events.
/// Per-request truth comes from the server's own `timings` object (the spec
/// pins this) for prefill/decode duration, while TTFT ends at the directly
/// observed first non-empty content-chunk arrival.
public enum LlamaRequestTrace {
    public static func events(
        runId: String,
        requestId: String,
        requestStartNs: UInt64,
        chunkArrivalsNs: [UInt64],
        chunks: [LlamaCompletionChunk],
        kv: KVCacheModel
    ) -> [EventEnvelope] {
        // The server is untrusted input: NaN/inf timings must become an
        // error trace, not a UInt64-conversion trap.
        guard let timings = chunks.last?.timings ?? chunks.compactMap(\.timings).last,
            timings.promptN >= 0, timings.predictedN >= 0,
            timings.promptMs.isFinite, timings.promptMs >= 0,
            timings.predictedMs.isFinite, timings.predictedMs >= 0,
            timings.predictedPerSecond.isFinite, timings.predictedPerSecond >= 0
        else {
            return sequenced([
                EventEnvelope(
                    ts: requestStartNs, runId: runId, requestId: requestId,
                    payload: .requestStart(RequestStartPayload(promptTokens: nil))),
                EventEnvelope(
                    ts: chunkArrivalsNs.last ?? requestStartNs, runId: runId,
                    requestId: requestId,
                    payload: .error(
                        ErrorPayload(
                            code: "missing_timings",
                            message: "completion stream ended without usable timings"))),
                EventEnvelope(
                    ts: chunkArrivalsNs.last ?? requestStartNs, runId: runId,
                    requestId: requestId,
                    payload: .requestEnd(
                        RequestEndPayload(outputTokens: 0, finishReason: "error"))),
            ])
        }

        let promptTokens = UInt32(clamping: timings.promptN)
        let promptDurationNs = nanoseconds(milliseconds: timings.promptMs)
        let predictedDurationNs = nanoseconds(milliseconds: timings.predictedMs)
        // llama.cpp's predicted_ms is the runtime's full generation window,
        // including the first predicted token. This is the same boundary
        // Loupe derives for MLX (prefill end → request end). The rate is a
        // consistency fallback only for older servers that report zero ms.
        let measuredDecodeDurationNs = decodeDuration(
            outputTokens: timings.predictedN,
            milliseconds: timings.predictedMs,
            tokensPerSecond: timings.predictedPerSecond)
        let modeledPrefillEndNs = adding(promptDurationNs, to: requestStartNs)
        let firstOutputArrivalNs = chunks.enumerated().first(where: { !$0.element.content.isEmpty })
            .flatMap { indexed in
                indexed.offset < chunkArrivalsNs.count
                    ? chunkArrivalsNs[indexed.offset] : nil
            }
        // A first output cannot precede prefill completion. If hostile or
        // inconsistent server timing says otherwise, preserve the directly
        // observed output arrival and clamp the modeled prefill boundary back.
        let prefillEndNs = max(
            requestStartNs,
            min(modeledPrefillEndNs, firstOutputArrivalNs ?? modeledPrefillEndNs))

        var events: [EventEnvelope] = [
            EventEnvelope(
                ts: requestStartNs, runId: runId, requestId: requestId,
                payload: .requestStart(RequestStartPayload(promptTokens: promptTokens))),
            EventEnvelope(
                ts: prefillEndNs, runId: runId, requestId: requestId,
                payload: .prefillEnd(PrefillEndPayload(promptTokens: promptTokens))),
        ]

        // One tick per streamed content chunk at its observed arrival time.
        // KV grows by the architecture model, computed — never read — per the spec.
        // activeMemoryBytes stays 0: this adapter has no view into the
        // server's allocator; per-process RSS is the daemon's job.
        var produced = 0
        for (index, chunk) in chunks.enumerated() where !chunk.content.isEmpty {
            produced += 1
            let ts = index < chunkArrivalsNs.count ? chunkArrivalsNs[index] : prefillEndNs
            let tokenTotal = timings.promptN.addingReportingOverflow(produced)
            events.append(
                EventEnvelope(
                    ts: max(ts, prefillEndNs), runId: runId, requestId: requestId,
                    payload: .decodeTick(
                        DecodeTickPayload(
                            outputTokens: UInt32(clamping: produced),
                            kvCacheBytes: kv.bytes(
                                forTokens: tokenTotal.overflow ? Int.max : tokenTotal.partialValue),
                            activeMemoryBytes: 0,
                            memoryProvenance: .architectureModeledKV))))
        }

        let modeledEnd = adding(
            adding(promptDurationNs, to: predictedDurationNs), to: requestStartNs)
        let endNs = max(chunkArrivalsNs.last ?? prefillEndNs, modeledEnd)
        events.append(
            EventEnvelope(
                ts: endNs, runId: runId, requestId: requestId,
                payload: .requestEnd(
                    RequestEndPayload(
                        outputTokens: UInt32(clamping: timings.predictedN),
                        finishReason: chunks.last?.stop == true ? "stop" : "length",
                        decodeDurationNs: measuredDecodeDurationNs))))
        return sequenced(events)
    }

    /// Standalone traces remain valid current-protocol lines in tests and file
    /// sinks. The executable replaces these request-local sequence numbers
    /// with its one session-wide sequence immediately before socket output.
    private static func sequenced(_ events: [EventEnvelope]) -> [EventEnvelope] {
        events.enumerated().map { index, envelope in
            EventEnvelope(
                version: EventProtocol.version, sequence: UInt64(index + 1),
                ts: envelope.ts, runId: envelope.runId,
                requestId: envelope.requestId, payload: envelope.payload)
        }
    }

    private static func nanoseconds(milliseconds: Double) -> UInt64 {
        guard milliseconds > 0 else { return 0 }
        let value = milliseconds * 1_000_000
        guard value.isFinite, value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value)
    }

    private static func adding(_ amount: UInt64, to value: UInt64) -> UInt64 {
        value <= UInt64.max - amount ? value + amount : UInt64.max
    }

    private static func decodeDuration(
        outputTokens: Int, milliseconds: Double, tokensPerSecond: Double
    ) -> UInt64? {
        guard outputTokens > 0 else {
            return nil
        }
        if milliseconds.isFinite, milliseconds > 0 {
            return nanoseconds(milliseconds: milliseconds)
        }
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return nil }
        let value = Double(outputTokens) / tokensPerSecond * 1_000_000_000
        guard value.isFinite, value > 0 else { return nil }
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value)
    }
}
