import Foundation

@testable import LoupeApp
@testable import LoupeSampler

/// Scripted DaemonServiceClient: no root, no SMAppService, and by default it
/// behaves like a user who denied the daemon.
final class MockDaemonClient: DaemonServiceClient, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: DaemonStatus
    private var statusAfterRegister: DaemonStatus
    var registerError: (any Error)?

    init(
        status: DaemonStatus = .notRegistered,
        statusAfterRegister: DaemonStatus = .requiresApproval
    ) {
        self.currentStatus = status
        self.statusAfterRegister = statusAfterRegister
    }

    func status() -> DaemonStatus {
        lock.withLock { currentStatus }
    }

    func set(status: DaemonStatus) {
        lock.withLock { currentStatus = status }
    }

    func register() throws {
        if let registerError { throw registerError }
        lock.withLock { currentStatus = statusAfterRegister }
    }

    func unregister() async throws {
        lock.withLock { currentStatus = .notRegistered }
    }

    func openApprovalSettings() {}

    func makeConnection() -> DaemonXPCClient? { nil }
}
