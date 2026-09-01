import Foundation
import LoupeCore

/// Comparison exports. The CSV mirrors what the table shows: deltas when
/// comparable, the mismatch list when not — an export must never contain a
/// cross-configuration delta the UI refused to display.
public enum ComparisonExport {
    public static func csv(
        baselineName: String, candidateName: String, comparison: RunComparison
    ) -> String {
        var lines: [String] = []
        if let deltas = comparison.deltas {
            lines.append(
                "context_tokens,metric,\(field(baselineName + "_p50")),"
                    + "\(field(candidateName + "_p50")),delta_percent"
            )
            for delta in deltas {
                lines.append(
                    "\(delta.contextTokens),\(field(delta.metric)),"
                        + String(
                            format: "%.4f,%.4f,%.2f",
                            locale: Locale(identifier: "en_US_POSIX"),
                            delta.baselineP50, delta.candidateP50, delta.deltaPercent))
            }
        } else {
            lines.append("mismatched_dimension,\(field(baselineName)),\(field(candidateName))")
            for mismatch in comparison.mismatches {
                lines.append(
                    "\(field(mismatch.name)),\(field(mismatch.baseline)),\(field(mismatch.candidate))"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public struct JSONPayload: Codable, Sendable {
        public let baseline: String
        public let candidate: String
        public let comparable: Bool
        public let mismatches: [Mismatch]
        public let deltas: [Delta]?

        public struct Mismatch: Codable, Sendable {
            public let dimension: String
            public let baseline: String
            public let candidate: String
        }

        public struct Delta: Codable, Sendable {
            public let contextTokens: Int
            public let metric: String
            public let baselineP50: Double
            public let candidateP50: Double
            public let deltaPercent: Double
        }
    }

    public static func json(
        baselineName: String, candidateName: String, comparison: RunComparison
    ) throws -> Data {
        let payload = JSONPayload(
            baseline: baselineName,
            candidate: candidateName,
            comparable: comparison.isComparable,
            mismatches: comparison.mismatches.map {
                JSONPayload.Mismatch(
                    dimension: $0.name, baseline: $0.baseline, candidate: $0.candidate)
            },
            deltas: comparison.deltas.map { deltas in
                deltas.map {
                    JSONPayload.Delta(
                        contextTokens: $0.contextTokens, metric: $0.metric,
                        baselineP50: $0.baselineP50, candidateP50: $0.candidateP50,
                        deltaPercent: $0.deltaPercent)
                }
            })
        return try JSONEncoder.deterministic().encode(payload)
    }

    /// CSV field sanitizer: preserve columns and prevent spreadsheet formulas
    /// from executing when filenames or report metadata are attacker-chosen.
    private static func field(_ raw: String) -> String {
        let safe: String
        if let first = raw.first,
            "=+-@".contains(first) || first == "\t" || first == "\r"
        {
            safe = "'" + raw
        } else {
            safe = raw
        }
        return safe.contains(",") || safe.contains("\"") || safe.contains("\n")
            || safe.contains("\r")
            ? "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : safe
    }
}
