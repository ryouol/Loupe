import Darwin
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
    public let acquisitionSource: Source?
    public let durationSeconds: Double
    public let eventCount: Int
    public let sampleCount: Int
    public let droppedEventLines: Int
    public let droppedSampleLines: Int
    public let eventAcquisitionLosses: AcquisitionLossCount?
    public let telemetryAcquisitionLosses: AcquisitionLossCount?
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
            "record_type,key,value,request_id,prompt_tokens,output_tokens,ttft_ms,decode_tokens_per_second,finding_kind,at_seconds,message"
        ]
        let provenance: [(String, String)] = [
            ("schema_version", String(report.schemaVersion)),
            ("generated_at", ISO8601DateFormatter().string(from: report.generatedAt)),
            ("session_name", report.sessionName),
            ("event_source_filename", report.eventSource.filename),
            ("event_source_sha256", report.eventSource.sha256),
            ("telemetry_source_filename", report.telemetrySource.filename),
            ("telemetry_source_sha256", report.telemetrySource.sha256),
            ("acquisition_source_filename", report.acquisitionSource?.filename ?? "unknown"),
            ("acquisition_source_sha256", report.acquisitionSource?.sha256 ?? "unknown"),
            ("duration_seconds", csvNumber(report.durationSeconds, decimals: 6)),
            ("event_count", String(report.eventCount)),
            ("sample_count", String(report.sampleCount)),
            ("replay_event_parser_drops", String(report.droppedEventLines)),
            ("replay_telemetry_parser_drops", String(report.droppedSampleLines)),
            (
                "event_acquisition_exact",
                report.eventAcquisitionLosses?.exact.map(String.init) ?? "unknown"
            ),
            (
                "event_acquisition_lower_bound",
                report.eventAcquisitionLosses.map(acquisitionLowerBound) ?? "unknown"
            ),
            (
                "event_acquisition_breakdown",
                report.eventAcquisitionLosses.map(acquisitionBreakdown) ?? "unknown"
            ),
            (
                "telemetry_acquisition_exact",
                report.telemetryAcquisitionLosses?.exact.map(String.init) ?? "unknown"
            ),
            (
                "telemetry_acquisition_lower_bound",
                report.telemetryAcquisitionLosses.map(acquisitionLowerBound) ?? "unknown"
            ),
            (
                "telemetry_acquisition_breakdown",
                report.telemetryAcquisitionLosses.map(acquisitionBreakdown) ?? "unknown"
            ),
            ("thermal_states", report.thermalStates.joined(separator: "|")),
        ]
        for (key, value) in provenance {
            rows.append(
                ["provenance", key, value, "", "", "", "", "", "", "", ""]
                    .map(csvCell).joined(separator: ","))
        }
        for request in report.requests {
            rows.append(
                [
                    "request", "", "", request.requestId, String(request.promptTokens),
                    String(request.outputTokens), csvNumber(request.ttftMs, decimals: 3),
                    csvNumber(request.decodeTokensPerSecond, decimals: 3), "", "", "",
                ].map(csvCell).joined(separator: ","))
        }
        for finding in report.findings {
            rows.append(
                [
                    "finding", "", "", "", "", "", "", "", finding.kind,
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
        let currentAcquisitionSource: SessionEvidenceReport.Source?
        var metadataNode = stat()
        if lstat(session.metadataURL.path, &metadataNode) == 0 {
            let metadataData = try ReplayResourceLimits.read(
                session.metadataURL, maximumBytes: 65_536)
            currentAcquisitionSource = .init(
                filename: session.metadataURL.lastPathComponent,
                sha256: Self.sourceSHA256(metadataData))
        } else if errno == ENOENT {
            currentAcquisitionSource = nil
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard currentEventSHA256 == eventSourceSHA256,
            currentTelemetrySHA256 == telemetrySourceSHA256,
            currentAcquisitionSource?.sha256 == acquisitionSourceSHA256
        else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "A session source changed after it was loaded. Reload before exporting evidence."
                ])
        }
        return SessionEvidenceReport(
            // v3 defines request TTFT as start → first observable output.
            schemaVersion: 3,
            generatedAt: Date(),
            sessionName: session.name,
            eventSource: .init(
                filename: session.eventsURL.lastPathComponent,
                sha256: currentEventSHA256),
            telemetrySource: .init(
                filename: session.systemURL.lastPathComponent,
                sha256: currentTelemetrySHA256),
            acquisitionSource: currentAcquisitionSource,
            durationSeconds: durationSeconds,
            eventCount: totalEventCount,
            sampleCount: samples.count,
            droppedEventLines: eventDrops,
            droppedSampleLines: sampleDrops,
            eventAcquisitionLosses: acquisitionMetadata?.eventLosses,
            telemetryAcquisitionLosses: acquisitionMetadata?.telemetryLosses,
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
        CSVFieldEncoder.encode(value)
    }

    private func csvNumber(_ value: Double, decimals: Int) -> String {
        String(
            format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func csvBreakdown(_ values: [String: Int]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? 0)" }.joined(separator: "|")
    }

    private func acquisitionLowerBound(_ losses: AcquisitionLossCount) -> String {
        losses.exact == nil && losses.lowerBound == 0 ? "unknown" : String(losses.lowerBound)
    }

    private func acquisitionBreakdown(_ losses: AcquisitionLossCount) -> String {
        losses.exact == nil && losses.lowerBound == 0 && losses.breakdown.isEmpty
            ? "unknown" : csvBreakdown(losses.breakdown)
    }
}
