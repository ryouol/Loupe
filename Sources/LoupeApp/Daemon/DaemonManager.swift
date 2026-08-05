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

/// Seam for daemon UI tests: production wires SMAppService, tests a mock.
public protocol DaemonServiceClient: Sendable {
    func status() -> DaemonStatus
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
    /// nil = unreachable; callers treat that as observed mode, not an error.
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
