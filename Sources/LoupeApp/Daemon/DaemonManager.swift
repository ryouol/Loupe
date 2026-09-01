import Foundation
import LoupeCore
import LoupeSampler
import Security
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
    func installationBlocker() -> String?
}

extension DaemonServiceClient {
    public func installationBlocker() -> String? { nil }
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
        if let blocker = installationBlocker() {
            throw DaemonInstallationError.blocked(blocker)
        }
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

    public func installationBlocker() -> String? {
        guard Self.currentTeamIdentifier() != nil else {
            return "The optional root helper requires an Apple-team-signed build. "
                + "This unsigned development build remains fully usable in local mode."
        }
        return nil
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                Bundle.main.bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
            let code
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        guard let identifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            identifier.count == 10,
            identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return identifier
    }
}

public enum DaemonInstallationError: LocalizedError {
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let detail): return detail
        }
    }
}
