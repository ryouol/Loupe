import Foundation

/// llama-server's `/props` payload — only the fields the adapter needs.
/// Unknown fields are ignored so server upgrades don't break parsing.
public struct LlamaServerProps: Decodable, Sendable, Equatable {
    public struct GenerationSettings: Decodable, Sendable, Equatable {
        public let nCtx: Int

        enum CodingKeys: String, CodingKey {
            case nCtx = "n_ctx"
        }
    }

    public let defaultGenerationSettings: GenerationSettings
    public let modelPath: String?
    public let totalSlots: Int?

    enum CodingKeys: String, CodingKey {
        case defaultGenerationSettings = "default_generation_settings"
        case modelPath = "model_path"
        case totalSlots = "total_slots"
    }
}

/// The per-request truth from `/completion`: llama.cpp measures these
/// server-side, so they beat anything reconstructed from arrival times.
public struct LlamaTimings: Decodable, Sendable, Equatable {
    public let promptN: Int
    public let promptMs: Double
    public let predictedN: Int
    public let predictedMs: Double
    public let predictedPerSecond: Double

    enum CodingKeys: String, CodingKey {
        case promptN = "prompt_n"
        case promptMs = "prompt_ms"
        case predictedN = "predicted_n"
        case predictedMs = "predicted_ms"
        case predictedPerSecond = "predicted_per_second"
    }
}

/// One streamed `/completion` chunk (SSE `data:` payload).
public struct LlamaCompletionChunk: Decodable, Sendable, Equatable {
    public let content: String
    public let stop: Bool
    public let timings: LlamaTimings?
}

/// KV cache size computed from architecture parameters — the spec forbids
/// trusting a runtime-reported number here. Layer/head geometry comes from
/// the GGUF metadata (mirrored into the run configuration), context from
/// `/props`.
public struct KVCacheModel: Sendable, Equatable {
    public let layers: Int
    public let headDimension: Int
    public let kvHeads: Int
    /// f16 K + f16 V per element unless the cache is quantized.
    public let bytesPerElement: Int

    public init(layers: Int, headDimension: Int, kvHeads: Int, bytesPerElement: Int = 2) {
        self.layers = layers
        self.headDimension = headDimension
        self.kvHeads = kvHeads
        self.bytesPerElement = bytesPerElement
    }

    /// K and V each store layers × kvHeads × headDim per token.
    public var bytesPerToken: Int {
        2 * layers * kvHeads * headDimension * bytesPerElement
    }

    public func bytes(forTokens tokens: Int) -> UInt64 {
        UInt64(max(0, tokens) * bytesPerToken)
    }
}

public enum PrometheusParser {
    /// Parses the exposition format `/metrics` serves: `name value` lines,
    /// `#` comments, label-free (llama.cpp emits no labels today; labeled
    /// series keep their bare name so future labels degrade gracefully).
    public static func parse(_ text: String) -> [String: Double] {
        var values: [String: Double] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let value = Double(parts[parts.count - 1]) else { continue }
            var name = String(parts[0])
            if let brace = name.firstIndex(of: "{") {
                name = String(name[..<brace])
            }
            values[name] = value
        }
        return values
    }
}

public enum SSEParser {
    /// Extracts the JSON payloads from a `text/event-stream` body: lines
    /// prefixed `data: `, blank-line separated. `[DONE]` sentinels skipped.
    public static func dataPayloads(_ body: String) -> [Data] {
        body.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return nil }
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { return nil }
            return Data(payload.utf8)
        }
    }

    public static func chunks(_ body: String) -> [LlamaCompletionChunk] {
        let decoder = JSONDecoder()
        return dataPayloads(body).compactMap {
            try? decoder.decode(LlamaCompletionChunk.self, from: $0)
        }
    }
}
