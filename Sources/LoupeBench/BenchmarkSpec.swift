import Foundation
import Yams

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
        try YAMLDecoder().decode(BenchmarkSpec.self, from: text)
    }

    /// The dimensions that must match for two reports to be comparable.
    public var comparableDimensions: [(name: String, value: String)] {
        [
            ("model", model),
            ("runtime", runtime),
            ("quantization", quantization),
            ("contexts", contexts.map(String.init).joined(separator: ",")),
            ("batch", String(batch)),
            ("outputTokens", String(outputTokens)),
            ("seed", String(seed)),
        ]
    }
}
