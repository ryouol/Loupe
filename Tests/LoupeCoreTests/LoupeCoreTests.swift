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
}
