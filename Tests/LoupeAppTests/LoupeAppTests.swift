import XCTest

@testable import LoupeApp

@MainActor
final class LoupeAppTests: XCTestCase {
    func testRootViewInstantiates() {
        _ = RootView()
    }
}
