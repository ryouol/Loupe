import Foundation
import LoupeCore
import LoupeSampler

public struct SessionEvidenceReport: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public let filename: String
        public let sha256: String
    }

    public struct Finding: Codable, Sendable, Equatable {
        public let kind: String
        public let atSeconds: Double
        public let message: String
        public let sampleTimestamps: [UInt64]
        public let eventTimestamps: [UInt64]
        public let values: [String: Double]
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let sessionName: String
    public let eventSource: Source
    public let telemetrySource: Source
    public let durationSeconds: Double
    public let eventCount: Int
    public let sampleCount: Int
    public let droppedEventLines: Int
    public let droppedSampleLines: Int
    public let thermalStates: [String]
    public let requests: [RequestMetrics]
    public let findings: [Finding]
}

extension ReplayViewModel {
    public func evidenceJSON() throws -> Data {
        try JSONEncoder.deterministic().encode(evidenceReport())
    }

    public func evidenceCSV() throws -> String {
        let report = try evidenceReport()
        var rows = [
            "record_type,request_id,prompt_tokens,output_tokens,ttft_ms,decode_tokens_per_second,finding_kind,at_seconds,message"
        ]
        for request in report.requests {
            rows.append(
                [
                    "request", request.requestId, String(request.promptTokens),
                    String(request.outputTokens), csvNumber(request.ttftMs, decimals: 3),
                    csvNumber(request.decodeTokensPerSecond, decimals: 3), "", "", "",
                ].map(csvCell).joined(separator: ","))
        }
        for finding in report.findings {
            rows.append(
                [
                    "finding", "", "", "", "", "", finding.kind,
                    csvNumber(finding.atSeconds, decimals: 6), finding.message,
                ].map(csvCell).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func evidenceReport() throws -> SessionEvidenceReport {
        guard isLoaded else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSLocalizedDescriptionKey: "Load the session before exporting evidence."
                ])
        }
        let eventData = try ReplayResourceLimits.read(
            session.eventsURL, maximumBytes: ReplayResourceLimits.maxEventFileBytes)
        let telemetryData = try ReplayResourceLimits.read(
            session.systemURL, maximumBytes: ReplayResourceLimits.maxTelemetryFileBytes)
        let currentEventSHA256 = Self.sourceSHA256(eventData)
        let currentTelemetrySHA256 = Self.sourceSHA256(telemetryData)
        guard currentEventSHA256 == eventSourceSHA256,
            currentTelemetrySHA256 == telemetrySourceSHA256
        else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "A session source changed after it was loaded. Reload before exporting evidence."
                ])
        }
        return SessionEvidenceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            sessionName: session.name,
            eventSource: .init(
                filename: session.eventsURL.lastPathComponent,
                sha256: currentEventSHA256),
            telemetrySource: .init(
                filename: session.systemURL.lastPathComponent,
                sha256: currentTelemetrySHA256),
            durationSeconds: durationSeconds,
            eventCount: totalEventCount,
            sampleCount: samples.count,
            droppedEventLines: eventDrops,
            droppedSampleLines: sampleDrops,
            thermalStates: thermalStatesSeen.map(\.rawValue).sorted(),
            requests: requestMetrics,
            findings: annotations.map { annotation in
                SessionEvidenceReport.Finding(
                    kind: annotation.kind.rawValue,
                    atSeconds: annotation.atSeconds,
                    message: annotation.message,
                    sampleTimestamps: annotation.evidence.sampleTimestamps,
                    eventTimestamps: annotation.evidence.eventTimestamps,
                    values: annotation.evidence.values)
            })
    }

    private func csvCell(_ value: String) -> String {
        let safeValue: String
        if let first = value.first,
            "=+-@".contains(first) || first == "\t" || first == "\r"
        {
            safeValue = "'" + value
        } else {
            safeValue = value
        }
        if safeValue.contains(",") || safeValue.contains("\"") || safeValue.contains("\n") {
            return "\"" + safeValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safeValue
    }

    private func csvNumber(_ value: Double, decimals: Int) -> String {
        String(
            format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
