import Foundation
import XCTest

@testable import LoupeCore

final class LoupeCoreTests: XCTestCase {
    func testTelemetryWireDecoderRejectsUnknownFields() throws {
        let sample = SystemSample(
            system: SystemWideSample(
                ts: 1, thermalState: .nominal, memoryUsedBytes: 2,
                memoryFreeBytes: 3, swapUsedBytes: 0),
            process: nil)
        let valid = try JSONEncoder().encode(sample)
        XCTAssertEqual(SystemSampleWireDecoder.decode(valid), sample)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["prompt"] = "must not be hidden in telemetry"
        let hostile = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(SystemSampleWireDecoder.decode(hostile))
    }

    func testVersionIsSet() {
        XCTAssertEqual(Loupe.version, "0.2.0")
    }

    func testTelemetryLossLowerBoundDoesNotDoubleCountSequenceEvidence() {
        let stats = TelemetryAcquisitionStats(
            droppedSamples: 2, sequenceGapLowerBound: 3, malformedSamples: 1,
            complete: true)
        XCTAssertEqual(stats.lowerBound, 3)

        let disjointKnownLosses = TelemetryAcquisitionStats(
            droppedSamples: 2, sequenceGapLowerBound: 1, malformedSamples: 3,
            complete: true)
        XCTAssertEqual(disjointKnownLosses.lowerBound, 5)
    }

    func testAcquisitionBreakdownRejectsArbitraryExportText() {
        XCTAssertFalse(
            AcquisitionLossCount(
                exact: nil, lowerBound: 0,
                breakdown: ["prompt_or_user_supplied_text": 0]
            ).isValid)
        XCTAssertTrue(
            AcquisitionLossCount(
                exact: 1, lowerBound: 1,
                breakdown: ["recording_validation": 1]
            ).isValid)
    }
}
