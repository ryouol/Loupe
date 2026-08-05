import XCTest

@testable import LoupeSampler

final class LoupeSamplerTests: XCTestCase {
    func testDefaultCadence() {
        XCTAssertEqual(SamplerPlaceholder.defaultCadenceHz, 10)
    }
}
