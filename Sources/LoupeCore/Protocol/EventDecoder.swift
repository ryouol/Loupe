import Foundation

/// Adapters are untrusted: every malformed line maps to a reason and a
/// counter bump, never a crash.
public enum EventDropReason: Error, Sendable, Equatable {
    case oversizedLine(bytes: Int)
    case malformedJSON
    case unsupportedVersion(Int)
    case unknownEvent(String)
    case invalidEnvelope(String)
    case invalidPayload(String)
    case missingRequestID(EventKind)

    /// Counter key, shared verbatim with the Python mirror.
    public var label: String {
        switch self {
        case .oversizedLine: return "oversized_line"
        case .malformedJSON: return "malformed_json"
        case .unsupportedVersion: return "unsupported_version"
        case .unknownEvent: return "unknown_event"
        case .invalidEnvelope: return "invalid_envelope"
        case .invalidPayload: return "invalid_payload"
        case .missingRequestID: return "missing_request_id"
        }
    }
}

/// Caller-owned so the decoder stays pure.
public struct EventDropCounter: Sendable, Equatable {
    public private(set) var total: Int = 0
    public private(set) var byReason: [String: Int] = [:]

    public init() {}

    public mutating func record(_ reason: EventDropReason) {
        if total < Int.max { total += 1 }
        let current = byReason[reason.label, default: 0]
        if current < Int.max { byReason[reason.label] = current + 1 }
    }
}

extension JSONEncoder {
    /// The one NDJSON output format: sorted keys keep fixtures and stored
    /// payloads diffable; raw slashes keep model ids readable.
    public static func deterministic() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension EventLineDecoder {
    /// Decodes a whole NDJSON blob, counting drops — the shared loop behind
    /// replay sources, bench-run parsing, and tests. Silent drop-discarding
    /// is the failure mode this exists to prevent.
    public func decodeLines(_ blob: Data) -> (envelopes: [EventEnvelope], drops: EventDropCounter) {
        var envelopes: [EventEnvelope] = []
        var drops = EventDropCounter()
        for line in blob.split(separator: UInt8(ascii: "\n")) {
            switch decode(line: Data(line)) {
            case .success(let envelope): envelopes.append(envelope)
            case .failure(let reason): drops.record(reason)
            }
        }
        return (envelopes, drops)
    }
}

public struct EventLineDecoder: Sendable {
    /// Enforced before parsing: bounds allocations against hostile adapters.
    /// Shared with the schema (`x-limits.maxLineBytes`) and the Python
    /// mirror; conformance tests in both languages pin the three together.
    public static let maxLineBytes = 65_536

    public init() {}

    public func decode(line: Data) -> Result<EventEnvelope, EventDropReason> {
        guard line.count <= Self.maxLineBytes else {
            return .failure(.oversizedLine(bytes: line.count))
        }

        guard
            let raw = try? JSONSerialization.jsonObject(with: line),
            let object = raw as? [String: Any]
        else {
            return .failure(.malformedJSON)
        }

        // Probe v/event first so their mismatches report as themselves.
        struct Probe: Decodable {
            let v: Int?
            let event: String?
        }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(Probe.self, from: line) else {
            return .failure(.malformedJSON)
        }
        guard let version = probe.v else {
            return .failure(.invalidEnvelope("missing v"))
        }
        guard version == EventProtocol.version else {
            return .failure(.unsupportedVersion(version))
        }
        guard let eventName = probe.event else {
            return .failure(.invalidEnvelope("missing event"))
        }
        guard let kind = EventKind(rawValue: eventName) else {
            return .failure(.unknownEvent(eventName))
        }

        let allowedEnvelopeKeys = Set(["v", "ts", "runId", "requestId", "event", "payload"])
        guard Set(object.keys).isSubset(of: allowedEnvelopeKeys) else {
            return .failure(.invalidEnvelope("unknown field"))
        }
        guard let payloadObject = object["payload"] as? [String: Any] else {
            return .failure(.invalidPayload("payload"))
        }
        guard Set(payloadObject.keys).isSubset(of: Self.allowedPayloadKeys(for: kind)) else {
            return .failure(.invalidPayload("unknown field"))
        }

        let envelope: EventEnvelope
        do {
            envelope = try decoder.decode(EventEnvelope.self, from: line)
        } catch let failure as EventPayloadDecodingFailure {
            return .failure(.invalidPayload(describe(failure.underlying)))
        } catch let error as DecodingError {
            return .failure(.invalidEnvelope(describe(error)))
        } catch {
            return .failure(.malformedJSON)
        }

        if envelope.kind.requiresRequestID && envelope.requestId == nil {
            return .failure(.missingRequestID(envelope.kind))
        }
        if let violation = semanticViolation(in: envelope) {
            return .failure(violation)
        }
        return .success(envelope)
    }

    /// The persisted payload boundary uses the same allow-list so database
    /// corruption cannot smuggle fields that synthesized Codable would
    /// otherwise ignore.
    public static func allowedPayloadKeys(for kind: EventKind) -> Set<String> {
        switch kind {
        case .sessionStart: return ["adapter", "adapterVersion", "runtime", "pid"]
        case .clockSync: return ["t0", "t1", "t2", "t3"]
        case .modelLoadStart: return ["modelId"]
        case .modelLoadEnd: return ["modelId", "ok", "weightsBytes"]
        case .requestStart: return ["promptTokens"]
        case .prefillEnd: return ["promptTokens"]
        case .decodeTick: return ["outputTokens", "kvCacheBytes", "activeMemoryBytes"]
        case .requestEnd: return ["outputTokens", "finishReason"]
        case .error: return ["code", "message"]
        }
    }

    private func semanticViolation(in envelope: EventEnvelope) -> EventDropReason? {
        guard isBoundedIdentifier(envelope.runId) else {
            return .invalidEnvelope("runId")
        }
        if let requestID = envelope.requestId, !isBoundedIdentifier(requestID) {
            return .invalidEnvelope("requestId")
        }

        switch envelope.payload {
        case .sessionStart(let payload):
            guard payload.pid > 0,
                isBoundedString(payload.adapter, maximum: 256),
                isBoundedString(payload.adapterVersion, maximum: 128),
                isBoundedString(payload.runtime, maximum: 128)
            else { return .invalidPayload("session_start") }
        case .modelLoadStart(let payload):
            guard isBoundedString(payload.modelId, maximum: 1_024) else {
                return .invalidPayload("modelId")
            }
        case .modelLoadEnd(let payload):
            guard isBoundedString(payload.modelId, maximum: 1_024) else {
                return .invalidPayload("modelId")
            }
        case .requestEnd(let payload):
            guard isBoundedString(payload.finishReason, maximum: 64) else {
                return .invalidPayload("finishReason")
            }
        case .error(let payload):
            guard isBoundedString(payload.code, maximum: 128), payload.message.count <= 4_096 else {
                return .invalidPayload("error")
            }
        case .clockSync, .requestStart, .prefillEnd, .decodeTick:
            break
        }
        return nil
    }

    private func isBoundedIdentifier(_ value: String) -> Bool {
        isBoundedString(value, maximum: 128)
    }

    private func isBoundedString(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
    }

    private func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: type(of: error))
        }
        switch decodingError {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
            .dataCorrupted(let context):
            return context.codingPath.map(\.stringValue).joined(separator: ".")
        @unknown default: return "decoding_error"
        }
    }
}

public struct EventLineEncoder: Sendable {
    public init() {}

    /// No trailing newline — the NDJSON writer owns framing.
    public func encode(_ envelope: EventEnvelope) throws -> Data {
        try JSONEncoder.deterministic().encode(envelope)
    }
}

/// Stateful semantic validation for a complete event stream. The line
/// decoder proves each envelope in isolation; this proves the envelopes form
/// one usable session rather than a collection of individually valid lies.
public struct EventStreamValidator: Sendable {
    private var runID: String?
    private var didStart = false
    private var activeRequests: Set<String> = []
    private var prefilledRequests: Set<String> = []
    private var seenRequestIDs: Set<String> = []
    private var outputTokens: [String: UInt32] = [:]
    private var lastTimestamp: UInt64?

    public init() {}

    public var hasStartedSession: Bool { didStart }
    public var hasOpenRequests: Bool { !activeRequests.isEmpty }

    public mutating func accepts(_ envelope: EventEnvelope) -> Bool {
        guard runID.map({ $0 == envelope.runId }) ?? true,
            lastTimestamp.map({ envelope.ts >= $0 }) ?? true
        else { return false }

        switch envelope.payload {
        case .sessionStart:
            runID = envelope.runId
            didStart = true
            activeRequests.removeAll(keepingCapacity: true)
            prefilledRequests.removeAll(keepingCapacity: true)
            outputTokens.removeAll(keepingCapacity: true)
        case .clockSync, .modelLoadStart, .modelLoadEnd, .error:
            guard didStart else { return false }
        case .requestStart:
            guard didStart, let requestID = envelope.requestId,
                activeRequests.count < 1_024,
                seenRequestIDs.insert(requestID).inserted,
                activeRequests.insert(requestID).inserted
            else { return false }
            outputTokens[requestID] = 0
        case .prefillEnd:
            guard let requestID = envelope.requestId,
                activeRequests.contains(requestID),
                prefilledRequests.insert(requestID).inserted
            else { return false }
        case .decodeTick(let payload):
            guard let requestID = envelope.requestId,
                activeRequests.contains(requestID),
                prefilledRequests.contains(requestID),
                payload.outputTokens >= (outputTokens[requestID] ?? 0)
            else { return false }
            outputTokens[requestID] = payload.outputTokens
        case .requestEnd(let payload):
            guard let requestID = envelope.requestId,
                activeRequests.contains(requestID),
                payload.outputTokens >= (outputTokens[requestID] ?? 0)
            else { return false }
            activeRequests.remove(requestID)
            prefilledRequests.remove(requestID)
            outputTokens.removeValue(forKey: requestID)
        }
        lastTimestamp = envelope.ts
        return true
    }
}
