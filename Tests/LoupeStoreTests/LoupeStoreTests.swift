import XCTest

@testable import LoupeStore

final class LoupeStoreTests: XCTestCase {
    func testSchemaStartsUnversioned() {
        XCTAssertEqual(StorePlaceholder.schemaVersion, 0)
    }
}
