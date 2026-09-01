import Foundation

public enum BenchmarkAdapterInvocationError: Error, Equatable {
    case invalidPromptSize
}

/// Process launch material with prompt bytes deliberately separated from
/// argv. Keeping corpus text on stdin avoids process-list disclosure and the
/// operating system's ARG_MAX ceiling.
public struct BenchmarkAdapterInvocation: Sendable, Equatable {
    public static let maxPromptBytes = 1_048_576

    public let arguments: [String]
    public let standardInput: Data

    public init(
        model: String, outputPath: String, contextTokens: Int, maxTokens: Int,
        seed: UInt64, runID: String, prompt: String
    ) throws {
        let input = Data(prompt.utf8)
        guard !input.isEmpty, input.count <= Self.maxPromptBytes else {
            throw BenchmarkAdapterInvocationError.invalidPromptSize
        }
        self.arguments = [
            "-m", "loupe_mlx.bench",
            "--model", model,
            "--out", outputPath,
            "--context-tokens", String(contextTokens),
            "--max-tokens", String(maxTokens),
            "--seed", String(seed),
            "--run-id", runID,
            "--prompt-stdin",
        ]
        self.standardInput = input
    }
}
