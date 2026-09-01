import Darwin
import Foundation
import LoupeCore

public struct BenchmarkProvenance: Codable, Sendable, Equatable {
    public let toolVersion: String
    public let adapterVersion: String
    public let runtimeVersion: String
    public let modelRevision: String
    public let modelArtifactSHA256: String
    public let dependencyLockSHA256: String

    public init(
        toolVersion: String, adapterVersion: String, runtimeVersion: String,
        modelRevision: String, modelArtifactSHA256: String,
        dependencyLockSHA256: String
    ) {
        self.toolVersion = toolVersion
        self.adapterVersion = adapterVersion
        self.runtimeVersion = runtimeVersion
        self.modelRevision = modelRevision
        self.modelArtifactSHA256 = modelArtifactSHA256
        self.dependencyLockSHA256 = dependencyLockSHA256
    }

    public var comparableDimensions: [(name: String, value: String)] {
        [
            ("provenance.toolVersion", toolVersion),
            ("provenance.adapterVersion", adapterVersion),
            ("provenance.runtimeVersion", runtimeVersion),
            ("provenance.modelRevision", modelRevision),
            ("provenance.modelArtifactSHA256", modelArtifactSHA256),
            ("provenance.dependencyLockSHA256", dependencyLockSHA256),
        ]
    }

    public var isComplete: Bool {
        let textFieldsArePresent = comparableDimensions.allSatisfy {
            let normalized = $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && $0.value.utf8.count <= 1_024
                && normalized.lowercased() != "unknown"
        }
        let hashesAreValid = [modelArtifactSHA256, dependencyLockSHA256].allSatisfy {
            $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit }
                && Set($0.lowercased()).count > 1
        }
        return textFieldsArePresent && hashesAreValid
    }
}

public struct BenchmarkReport: Codable, Sendable, Equatable {
    public struct ContextResult: Codable, Sendable, Equatable {
        public let contextTokens: Int
        /// Post-warmup runs only; warmup is discarded before assembly.
        public let runs: [RunResult]
        public let ttftMs: DistributionSummary
        public let decodeTokensPerSecond: DistributionSummary
    }

    public struct RunResult: Codable, Sendable, Equatable {
        public let runIndex: Int
        public let requests: [RequestMetrics]
    }

    public let formatVersion: Int
    public let spec: BenchmarkSpec
    public let host: HostFingerprint
    public let createdAtNs: UInt64
    /// nil only when decoding a legacy v1 report. Legacy reports remain
    /// viewable, but the comparison gate refuses evidence-free deltas.
    public let provenance: BenchmarkProvenance?
    public let contexts: [ContextResult]

    public init(
        formatVersion: Int, spec: BenchmarkSpec, host: HostFingerprint,
        createdAtNs: UInt64, provenance: BenchmarkProvenance? = nil,
        contexts: [ContextResult]
    ) {
        self.formatVersion = formatVersion
        self.spec = spec
        self.host = host
        self.createdAtNs = createdAtNs
        self.provenance = provenance
        self.contexts = contexts
    }

    public var validationFailures: [String] {
        var failures: [String] = []
        if formatVersion != BenchmarkAssembler.formatVersion {
            failures.append("formatVersion")
        }
        if provenance?.isComplete != true {
            failures.append("provenance")
        }
        failures.append(contentsOf: spec.validationFailures.map { "spec.\($0)" })
        let hostText = [host.chip, host.model, host.osVersion, host.osBuild]
        if hostText.contains(where: {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty || normalized.utf8.count > 1_024
                || normalized.lowercased() == "unknown"
        }) || host.memoryBytes == 0 || host.performanceCores < 0
            || host.efficiencyCores < 0
            || (host.performanceCores == 0 && host.efficiencyCores == 0)
        {
            failures.append("host")
        }
        if createdAtNs == 0 { failures.append("createdAtNs") }
        if contexts.count != spec.contexts.count
            || Set(contexts.map(\.contextTokens)) != Set(spec.contexts)
        {
            failures.append("contexts")
        }
        if contexts.contains(where: { $0.runs.count != spec.repeats }) {
            failures.append("repeats")
        }
        if contexts.contains(where: { context in
            context.runs.map(\.runIndex) != Array(0..<context.runs.count)
                || context.runs.contains(where: { $0.requests.count != spec.batch })
        }) {
            failures.append("measuredRuns")
        }
        if contexts.contains(where: { context in
            context.runs.contains(where: { run in
                let requestIDs = run.requests.map(\.requestId)
                return Set(requestIDs).count != requestIDs.count
                    || run.requests.contains(where: { request in
                        request.requestId.isEmpty || request.requestId.utf8.count > 128
                            || request.promptTokens != context.contextTokens
                            || request.outputTokens != spec.outputTokens
                            || request.ttftNs == 0 || request.decodeDurationNs == 0
                    })
            })
        }) {
            failures.append("requestMetrics")
        }
        if contexts.contains(where: { context in
            let requests = context.runs.flatMap(\.requests)
            return !Self.matches(
                context.ttftMs, DistributionSummary(values: requests.map(\.ttftMs)))
                || !Self.matches(
                    context.decodeTokensPerSecond,
                    DistributionSummary(values: requests.map(\.decodeTokensPerSecond)))
        }) {
            failures.append("summaries")
        }
        return failures
    }

    private static func matches(_ lhs: DistributionSummary, _ rhs: DistributionSummary) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return [
            (lhs.p50, rhs.p50), (lhs.p95, rhs.p95), (lhs.mean, rhs.mean),
            (lhs.stddev, rhs.stddev), (lhs.min, rhs.min), (lhs.max, rhs.max),
        ].allSatisfy { first, second in
            first.isFinite && second.isFinite
                && abs(first - second) <= max(1e-9, abs(second) * 1e-9)
        }
    }
}

public enum BenchmarkAssembler {
    /// Format v3 defines TTFT as request_start → first positive decode_tick.
    public static let formatVersion = 3
    public static let maxReportBytes = 16 * 1_024 * 1_024

    /// Pure assembly: measured event streams in, stable report out. The
    /// golden-file test pins this structure.
    public static func report(
        spec: BenchmarkSpec,
        host: HostFingerprint,
        createdAtNs: UInt64,
        provenance: BenchmarkProvenance? = nil,
        measuredRunsByContext: [Int: [[EventEnvelope]]]
    ) -> BenchmarkReport {
        let contexts = measuredRunsByContext.keys.sorted().map { context in
            let runs = (measuredRunsByContext[context] ?? []).enumerated().map { index, events in
                BenchmarkReport.RunResult(
                    runIndex: index, requests: SessionMetrics.perRequest(events: events))
            }
            let allRequests = runs.flatMap(\.requests)
            return BenchmarkReport.ContextResult(
                contextTokens: context,
                runs: runs,
                ttftMs: DistributionSummary(values: allRequests.map(\.ttftMs)),
                decodeTokensPerSecond: DistributionSummary(
                    values: allRequests.map(\.decodeTokensPerSecond)))
        }
        return BenchmarkReport(
            formatVersion: formatVersion,
            spec: spec,
            host: host,
            createdAtNs: createdAtNs,
            provenance: provenance,
            contexts: contexts)
    }

    public static func encode(_ report: BenchmarkReport) throws -> Data {
        try JSONEncoder.deterministic().encode(report)
    }

    public static func decode(_ data: Data) throws -> BenchmarkReport {
        guard data.count <= maxReportBytes, hasExactWireShape(data),
            let report = try? JSONDecoder().decode(BenchmarkReport.self, from: data)
        else { throw BenchmarkDecodeError.invalidFile }
        return report
    }

    public static func decode(contentsOf url: URL) throws -> BenchmarkReport {
        try decode(boundedFileData(at: url))
    }

    private static func hasExactWireShape(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data),
            let root = exactObject(
                value,
                required: ["formatVersion", "spec", "host", "createdAtNs", "contexts"],
                optional: ["provenance"]),
            exactObject(
                root["spec"],
                required: [
                    "model", "runtime", "quantization", "contexts", "batch", "promptCorpus",
                    "outputTokens", "repeats", "warmup", "seed", "cooldownTimeoutSeconds",
                ]) != nil,
            exactObject(
                root["host"],
                required: [
                    "chip", "model", "performanceCores", "efficiencyCores", "memoryBytes",
                    "osVersion", "osBuild",
                ]) != nil,
            let contexts = root["contexts"] as? [Any]
        else { return false }

        if let provenance = root["provenance"], !(provenance is NSNull),
            exactObject(
                provenance,
                required: [
                    "toolVersion", "adapterVersion", "runtimeVersion", "modelRevision",
                    "modelArtifactSHA256", "dependencyLockSHA256",
                ]) == nil
        {
            return false
        }

        return contexts.allSatisfy { value in
            guard
                let context = exactObject(
                    value,
                    required: [
                        "contextTokens", "runs", "ttftMs", "decodeTokensPerSecond",
                    ]),
                let runs = context["runs"] as? [Any],
                summaryHasExactShape(context["ttftMs"]),
                summaryHasExactShape(context["decodeTokensPerSecond"])
            else { return false }
            return runs.allSatisfy { value in
                guard let run = exactObject(value, required: ["runIndex", "requests"]),
                    let requests = run["requests"] as? [Any]
                else { return false }
                return requests.allSatisfy {
                    exactObject(
                        $0,
                        required: [
                            "requestId", "promptTokens", "outputTokens", "ttftNs",
                            "decodeDurationNs",
                        ]) != nil
                }
            }
        }
    }

    private static func summaryHasExactShape(_ value: Any?) -> Bool {
        exactObject(
            value,
            required: ["count", "p50", "p95", "mean", "stddev", "min", "max"])
            != nil
    }

    private static func exactObject(
        _ value: Any?, required: Set<String>, optional: Set<String> = []
    ) -> [String: Any]? {
        guard let object = value as? [String: Any] else { return nil }
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            return nil
        }
        return object
    }

    private static func boundedFileData(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BenchmarkDecodeError.invalidFile }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size >= 0,
            metadata.st_size <= off_t(maxReportBytes)
        else { throw BenchmarkDecodeError.invalidFile }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        while true {
            var buffer = [UInt8](
                repeating: 0, count: min(65_536, maxReportBytes - data.count + 1))
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw BenchmarkDecodeError.invalidFile
            }
            guard data.count <= maxReportBytes - count else {
                throw BenchmarkDecodeError.invalidFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

public enum BenchmarkDecodeError: LocalizedError {
    case invalidFile

    public var errorDescription: String? {
        "Benchmark reports must be regular JSON files no larger than 16 MiB."
    }
}
