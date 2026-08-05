import Foundation
import LoupeCore
import LoupeSampler
import ServiceManagement

public enum DaemonStatus: Sendable, Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case unknown(String)
}

/// The seam that keeps daemon UI testable: the view model talks to this,
/// production wires SMAppService, tests wire a scripted mock.
public protocol DaemonServiceClient: Sendable {
    func status() -> DaemonStatus
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
    /// nil when the daemon can't be reached (not installed / not approved) —
    /// callers must treat that as observed mode, never as an error.
    func makeConnection() -> DaemonXPCClient?
}

public struct SMAppServiceDaemonClient: DaemonServiceClient {
    public init() {}

    private var service: SMAppService {
        SMAppService.daemon(plistName: LoupeDaemon.plistName)
    }

    public func status() -> DaemonStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown(String(describing: service.status))
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        try await service.unregister()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func makeConnection() -> DaemonXPCClient? {
        guard case .enabled = status() else { return nil }
        return DaemonXPCClient()
    }
}

/// Scripted client for tests and previews: no root, no SMAppService, and by
/// default it behaves like a user who denied the daemon.
public final class MockDaemonClient: DaemonServiceClient, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: DaemonStatus
    private var statusAfterRegister: DaemonStatus
    public var registerError: (any Error)?

    public init(
        status: DaemonStatus = .notRegistered,
        statusAfterRegister: DaemonStatus = .requiresApproval
    ) {
        self.currentStatus = status
        self.statusAfterRegister = statusAfterRegister
    }

    public func status() -> DaemonStatus {
        lock.withLock { currentStatus }
    }

    public func set(status: DaemonStatus) {
        lock.withLock { currentStatus = status }
    }

    public func register() throws {
        if let registerError { throw registerError }
        lock.withLock { currentStatus = statusAfterRegister }
    }

    public func unregister() async throws {
        lock.withLock { currentStatus = .notRegistered }
    }

    public func openApprovalSettings() {}

    public func makeConnection() -> DaemonXPCClient? { nil }
}
