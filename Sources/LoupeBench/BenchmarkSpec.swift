import CryptoKit
import Foundation
import Yams

public enum BenchmarkSpecDecodeError: LocalizedError {
    case unexpectedFields
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unexpectedFields:
            return "Benchmark specifications must contain exactly the documented fields."
        case .tooLarge: return "Benchmark specifications cannot exceed 1 MiB of UTF-8 text."
        }
    }
}

/// One benchmark definition. Two runs are comparable only when their specs
/// match — the comparison engine (M3.2) diffs these field by field.
public struct BenchmarkSpec: Codable, Sendable, Equatable {
    public var model: String
    public var runtime: String
    public var quantization: String
    /// Prompt lengths to sweep, in tokens.
    public var contexts: [Int]
    public var batch: Int
    public var promptCorpus: [String]
    public var outputTokens: Int
    /// Measured repetitions per context, after `warmup` discarded runs.
    public var repeats: Int
    public var warmup: Int
    public var seed: UInt64
    public var cooldownTimeoutSeconds: Double

    public init(
        model: String, runtime: String, quantization: String, contexts: [Int],
        batch: Int = 1, promptCorpus: [String], outputTokens: Int,
        repeats: Int, warmup: Int = 1, seed: UInt64 = 42,
        cooldownTimeoutSeconds: Double = 120
    ) {
        self.model = model
        self.runtime = runtime
        self.quantization = quantization
        self.contexts = contexts
        self.batch = batch
        self.promptCorpus = promptCorpus
        self.outputTokens = outputTokens
        self.repeats = repeats
        self.warmup = warmup
        self.seed = seed
        self.cooldownTimeoutSeconds = cooldownTimeoutSeconds
    }

    public static func fromYAML(_ text: String) throws -> BenchmarkSpec {
        let allowedKeys: Set<String> = [
            "model", "runtime", "quantization", "contexts", "batch", "promptCorpus",
            "outputTokens", "repeats", "warmup", "seed", "cooldownTimeoutSeconds",
        ]
        guard text.utf8.count <= 1_048_576 else { throw BenchmarkSpecDecodeError.tooLarge }
        guard let raw = try Yams.load(yaml: text) as? [String: Any],
            Set(raw.keys) == allowedKeys
        else { throw BenchmarkSpecDecodeError.unexpectedFields }
        return try YAMLDecoder().decode(BenchmarkSpec.self, from: text)
    }

    public var validationFailures: [String] {
        var failures: [String] = []
        let identifiers = [model, runtime, quantization]
        if identifiers.contains(where: {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty || normalized.utf8.count > 1_024
                || normalized.lowercased() == "unknown"
        }) {
            failures.append("identity")
        }
        if contexts.isEmpty || contexts.count > 32 || Set(contexts).count != contexts.count
            || contexts.contains(where: { !(1...131_072).contains($0) })
        {
            failures.append("contexts")
        }
        if batch != 1 { failures.append("batch") }
        if promptCorpus.isEmpty || promptCorpus.count > 100
            || promptCorpus.contains(where: { $0.isEmpty })
            || promptCorpus.reduce(0, { $0 + $1.utf8.count }) > 1_048_576
        {
            failures.append("promptCorpus")
        }
        if !(1...4_096).contains(outputTokens) { failures.append("outputTokens") }
        if !(1...100).contains(repeats) { failures.append("repeats") }
        if !(0...20).contains(warmup) || repeats + warmup > 120 {
            failures.append("warmup")
        }
        if !cooldownTimeoutSeconds.isFinite || !(1...3_600).contains(cooldownTimeoutSeconds) {
            failures.append("cooldownTimeoutSeconds")
        }
        return failures
    }

    /// The dimensions that must match for two reports to be comparable.
    public var comparableDimensions: [(name: String, value: String)] {
        [
            ("model", model),
            ("runtime", runtime),
            ("quantization", quantization),
            ("contexts", contexts.map(String.init).joined(separator: ",")),
            ("batch", String(batch)),
            ("promptCorpusSHA256", promptCorpusSHA256),
            ("outputTokens", String(outputTokens)),
            ("repeats", String(repeats)),
            ("warmup", String(warmup)),
            ("seed", String(seed)),
            ("cooldownTimeoutSeconds", String(cooldownTimeoutSeconds)),
        ]
    }

    public var promptCorpusSHA256: String {
        var bytes = Data()
        for prompt in promptCorpus {
            var length = UInt64(prompt.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: prompt.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
