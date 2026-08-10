import XCTest

@testable import LoupeCore

final class LoupeCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(Loupe.version, "0.1.0")
    }
}
