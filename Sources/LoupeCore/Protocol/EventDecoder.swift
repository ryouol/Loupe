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
        total += 1
        byReason[reason.label, default: 0] += 1
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
        guard EventKind(rawValue: eventName) != nil else {
            return .failure(.unknownEvent(eventName))
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
        return .success(envelope)
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
