/// Event protocol v1 — hand-written mirror of `protocol/events.schema.json`.
/// Drift is caught by cross-language round-trip and schema-conformance tests
/// over the same committed examples.
public enum EventProtocol {
    public static let version = 1
}

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session_start"
    case clockSync = "clock_sync"
    case modelLoadStart = "model_load_start"
    case modelLoadEnd = "model_load_end"
    case requestStart = "request_start"
    case prefillEnd = "prefill_end"
    case decodeTick = "decode_tick"
    case requestEnd = "request_end"
    case error = "error"

    /// Request-scoped events drop without a requestId — never guess one.
    public var requiresRequestID: Bool {
        switch self {
        case .requestStart, .prefillEnd, .decodeTick, .requestEnd: return true
        case .sessionStart, .clockSync, .modelLoadStart, .modelLoadEnd, .error: return false
        }
    }
}

// MARK: - Payloads
// Unsigned counts/sizes: negative adapter input fails decoding for free.

public struct SessionStartPayload: Codable, Sendable, Equatable {
    public let adapter: String
    public let adapterVersion: String
    public let runtime: String
    public let pid: Int32

    public init(adapter: String, adapterVersion: String, runtime: String, pid: Int32) {
        self.adapter = adapter
        self.adapterVersion = adapterVersion
        self.runtime = runtime
        self.pid = pid
    }
}

/// The four-timestamp handshake payload; feeds `ClockSyncSample`.
public struct ClockSyncPayload: Codable, Sendable, Equatable {
    public let t0: UInt64
    public let t1: UInt64
    public let t2: UInt64
    public let t3: UInt64

    public init(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) {
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
    }

    public var sample: ClockSyncSample {
        ClockSyncSample(t0: t0, t1: t1, t2: t2, t3: t3)
    }
}

public struct ModelLoadStartPayload: Codable, Sendable, Equatable {
    public let modelId: String

    public init(modelId: String) {
        self.modelId = modelId
    }
}

public struct ModelLoadEndPayload: Codable, Sendable, Equatable {
    public let modelId: String
    public let ok: Bool
    public let weightsBytes: UInt64?

    public init(modelId: String, ok: Bool, weightsBytes: UInt64?) {
        self.modelId = modelId
        self.ok = ok
        self.weightsBytes = weightsBytes
    }
}

public struct RequestStartPayload: Codable, Sendable, Equatable {
    public let promptTokens: UInt32?

    public init(promptTokens: UInt32?) {
        self.promptTokens = promptTokens
    }
}

public struct PrefillEndPayload: Codable, Sendable, Equatable {
    public let promptTokens: UInt32

    public init(promptTokens: UInt32) {
        self.promptTokens = promptTokens
    }
}

public struct DecodeTickPayload: Codable, Sendable, Equatable {
    public let outputTokens: UInt32
    public let kvCacheBytes: UInt64
    public let activeMemoryBytes: UInt64

    public init(outputTokens: UInt32, kvCacheBytes: UInt64, activeMemoryBytes: UInt64) {
        self.outputTokens = outputTokens
        self.kvCacheBytes = kvCacheBytes
        self.activeMemoryBytes = activeMemoryBytes
    }
}

public struct RequestEndPayload: Codable, Sendable, Equatable {
    public let outputTokens: UInt32
    public let finishReason: String

    public init(outputTokens: UInt32, finishReason: String) {
        self.outputTokens = outputTokens
        self.finishReason = finishReason
    }
}

public struct ErrorPayload: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Envelope

public enum EventPayload: Sendable, Equatable {
    case sessionStart(SessionStartPayload)
    case clockSync(ClockSyncPayload)
    case modelLoadStart(ModelLoadStartPayload)
    case modelLoadEnd(ModelLoadEndPayload)
    case requestStart(RequestStartPayload)
    case prefillEnd(PrefillEndPayload)
    case decodeTick(DecodeTickPayload)
    case requestEnd(RequestEndPayload)
    case error(ErrorPayload)

    public var kind: EventKind {
        switch self {
        case .sessionStart: return .sessionStart
        case .clockSync: return .clockSync
        case .modelLoadStart: return .modelLoadStart
        case .modelLoadEnd: return .modelLoadEnd
        case .requestStart: return .requestStart
        case .prefillEnd: return .prefillEnd
        case .decodeTick: return .decodeTick
        case .requestEnd: return .requestEnd
        case .error: return .error
        }
    }
}

public struct EventEnvelope: Sendable, Equatable {
    public let v: Int
    /// Continuous-clock ns on the *emitter's* clock; clock_sync maps it here.
    public let ts: UInt64
    public let runId: String
    public let requestId: String?
    public let payload: EventPayload

    public var kind: EventKind { payload.kind }

    public init(ts: UInt64, runId: String, requestId: String?, payload: EventPayload) {
        self.v = EventProtocol.version
        self.ts = ts
        self.runId = runId
        self.requestId = requestId
        self.payload = payload
    }
}

/// Separates payload failures from envelope failures; JSONDecoder's
/// codingPath truncates on number-range errors, so a marker is required.
struct EventPayloadDecodingFailure: Error {
    let underlying: any Error
}

extension EventEnvelope: Codable {
    enum CodingKeys: String, CodingKey {
        case v, ts, runId, requestId, event, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try container.decode(Int.self, forKey: .v)
        self.ts = try container.decode(UInt64.self, forKey: .ts)
        self.runId = try container.decode(String.self, forKey: .runId)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        let kind = try container.decode(EventKind.self, forKey: .event)
        do {
            switch kind {
            case .sessionStart:
                self.payload = .sessionStart(
                    try container.decode(SessionStartPayload.self, forKey: .payload))
            case .clockSync:
                self.payload = .clockSync(
                    try container.decode(ClockSyncPayload.self, forKey: .payload))
            case .modelLoadStart:
                self.payload = .modelLoadStart(
                    try container.decode(ModelLoadStartPayload.self, forKey: .payload))
            case .modelLoadEnd:
                self.payload = .modelLoadEnd(
                    try container.decode(ModelLoadEndPayload.self, forKey: .payload))
            case .requestStart:
                self.payload = .requestStart(
                    try container.decode(RequestStartPayload.self, forKey: .payload))
            case .prefillEnd:
                self.payload = .prefillEnd(
                    try container.decode(PrefillEndPayload.self, forKey: .payload))
            case .decodeTick:
                self.payload = .decodeTick(
                    try container.decode(DecodeTickPayload.self, forKey: .payload))
            case .requestEnd:
                self.payload = .requestEnd(
                    try container.decode(RequestEndPayload.self, forKey: .payload))
            case .error:
                self.payload = .error(
                    try container.decode(ErrorPayload.self, forKey: .payload))
            }
        } catch {
            throw EventPayloadDecodingFailure(underlying: error)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(ts, forKey: .ts)
        try container.encode(runId, forKey: .runId)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encode(kind, forKey: .event)
        switch payload {
        case .sessionStart(let p): try container.encode(p, forKey: .payload)
        case .clockSync(let p): try container.encode(p, forKey: .payload)
        case .modelLoadStart(let p): try container.encode(p, forKey: .payload)
        case .modelLoadEnd(let p): try container.encode(p, forKey: .payload)
        case .requestStart(let p): try container.encode(p, forKey: .payload)
        case .prefillEnd(let p): try container.encode(p, forKey: .payload)
        case .decodeTick(let p): try container.encode(p, forKey: .payload)
        case .requestEnd(let p): try container.encode(p, forKey: .payload)
        case .error(let p): try container.encode(p, forKey: .payload)
        }
    }
}
