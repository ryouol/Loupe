import XCTest

@testable import LoupeCore

final class CSVFieldEncoderTests: XCTestCase {
    func testLeadingControlCannotHideFormulaPrefix() {
        XCTAssertEqual(
            CSVFieldEncoder.encode("\u{0001}  =SUM(A1:A2)"),
            "'\u{FFFD}  =SUM(A1:A2)")
    }

    func testUnicodeAndQuotesArePreservedAndEscaped() {
        XCTAssertEqual(
            CSVFieldEncoder.encode("Café, \"東京\""),
            "\"Café, \"\"東京\"\"\"")
    }
}
