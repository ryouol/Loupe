import Foundation
import LoupeCore

/// Maps one streamed `/completion` exchange onto protocol-v1 events.
/// Per-request truth comes from the server's own `timings` object (the spec
/// pins this): prefill_end sits at request_start + prompt_ms rather than at
/// first-chunk arrival, which would fold network latency into TTFT.
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
            timings.promptMs.isFinite, timings.predictedMs.isFinite
        else {
            return [
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
            ]
        }

        let promptTokens = UInt32(clamping: timings.promptN)
        let prefillEndNs = requestStartNs + UInt64(max(0, timings.promptMs) * 1_000_000)

        var events: [EventEnvelope] = [
            EventEnvelope(
                ts: requestStartNs, runId: runId, requestId: requestId,
                payload: .requestStart(RequestStartPayload(promptTokens: promptTokens))),
            EventEnvelope(
                ts: prefillEndNs, runId: runId, requestId: requestId,
                payload: .prefillEnd(PrefillEndPayload(promptTokens: promptTokens))),
        ]

        // One tick per streamed content chunk at its arrival time, clamped
        // forward to prefill_end: server-truth prompt_ms can postdate the
        // first chunks' arrivals, and a tick before its own prefill would be
        // a lie worse than a few collapsed early timestamps. KV grows by the
        // architecture model, computed — never read — per the spec.
        // activeMemoryBytes stays 0: this adapter has no view into the
        // server's allocator; per-process RSS is the daemon's job.
        var produced = 0
        for (index, chunk) in chunks.enumerated() where !chunk.content.isEmpty {
            produced += 1
            let ts = index < chunkArrivalsNs.count ? chunkArrivalsNs[index] : prefillEndNs
            events.append(
                EventEnvelope(
                    ts: max(ts, prefillEndNs), runId: runId, requestId: requestId,
                    payload: .decodeTick(
                        DecodeTickPayload(
                            outputTokens: UInt32(produced),
                            kvCacheBytes: kv.bytes(forTokens: timings.promptN + produced),
                            activeMemoryBytes: 0))))
        }

        let endNs = max(
            chunkArrivalsNs.last ?? prefillEndNs,
            requestStartNs + UInt64(max(0, timings.promptMs + timings.predictedMs) * 1_000_000))
        events.append(
            EventEnvelope(
                ts: endNs, runId: runId, requestId: requestId,
                payload: .requestEnd(
                    RequestEndPayload(
                        outputTokens: UInt32(clamping: timings.predictedN),
                        finishReason: chunks.last?.stop == true ? "stop" : "length"))))
        return events
    }
}
