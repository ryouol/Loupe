import Foundation
import XCTest

@testable import LoupeApp

/// The full status state machine against the scripted mock — most
/// importantly the denial path: the app must degrade to observed mode, never
/// crash, never block.
@MainActor
final class DaemonViewModelTests: XCTestCase {

    func testFreshInstallFlowReachesApprovalThenEnabled() {
        let client = MockDaemonClient(
            status: .notRegistered, statusAfterRegister: .requiresApproval)
        let model = DaemonViewModel(client: client)

        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertTrue(model.isObservedMode)

        model.install()
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertTrue(model.isObservedMode, "approval pending is still observed mode")
        XCTAssertNil(model.lastActionError)

        // User approves in System Settings; app refreshes.
        client.set(status: .enabled)
        model.refresh()
        XCTAssertEqual(model.status, .enabled)
        XCTAssertFalse(model.isObservedMode)
    }

    func testDenialDegradesToObservedModeWithoutError() {
        struct Denied: LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }
        let client = MockDaemonClient(status: .notRegistered)
        client.registerError = Denied()
        let model = DaemonViewModel(client: client)

        model.install()

        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertTrue(model.isObservedMode)
        XCTAssertEqual(model.lastActionError, "Operation not permitted")
        // Denied daemon must not produce a connection or a stream.
        model.startStreaming()
        XCTAssertEqual(model.samplesReceived, 0)
    }

    func testUninstallReturnsToNotRegistered() async {
        let client = MockDaemonClient(status: .enabled)
        let model = DaemonViewModel(client: client)
        XCTAssertFalse(model.isObservedMode)

        await model.uninstall()
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertTrue(model.isObservedMode)
    }

    func testEveryStatusHasAHumanLabel() {
        let statuses: [DaemonStatus] = [
            .notRegistered, .requiresApproval, .enabled, .notFound, .unknown("x"),
        ]
        for status in statuses {
            let client = MockDaemonClient(status: status)
            let model = DaemonViewModel(client: client)
            XCTAssertFalse(model.statusLabel.isEmpty)
        }
    }

    func testDaemonViewInstantiatesInEveryState() {
        for status in [DaemonStatus.notRegistered, .requiresApproval, .enabled, .notFound] {
            _ = DaemonView(model: DaemonViewModel(client: MockDaemonClient(status: status)))
        }
    }
}
