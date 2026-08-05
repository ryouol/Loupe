import Foundation
import LoupeCore
import LoupeSampler
import Observation

/// Install/approval state machine plus the live sample readout. The one hard
/// requirement: a denied or missing daemon degrades to observed mode — it
/// must never crash or block the app.
@MainActor
@Observable
public final class DaemonViewModel {
    private let client: any DaemonServiceClient
    private var streamTask: Task<Void, Never>?

    public private(set) var status: DaemonStatus
    public private(set) var lastActionError: String?
    public private(set) var latestSample: SystemSample?
    public private(set) var samplesReceived = 0
    public private(set) var handshake: DaemonHandshake?

    public init(client: any DaemonServiceClient = SMAppServiceDaemonClient()) {
        self.client = client
        self.status = client.status()
    }

    /// Observed mode: the app still works, reading only what an unprivileged
    /// process can see; privileged channels need the daemon.
    public var isObservedMode: Bool { status != .enabled }

    public var statusLabel: String {
        switch status {
        case .notRegistered: return "Not installed"
        case .requiresApproval: return "Waiting for approval in System Settings"
        case .enabled: return "Running"
        case .notFound: return "Daemon missing from app bundle"
        case .unknown(let detail): return "Unknown status (\(detail))"
        }
    }

    public func refresh() {
        status = client.status()
    }

    public func install() {
        lastActionError = nil
        do {
            try client.register()
        } catch {
            // Denial is a supported path, not a failure mode.
            lastActionError = error.localizedDescription
        }
        refresh()
        if status == .requiresApproval {
            client.openApprovalSettings()
        }
    }

    public func uninstall() async {
        lastActionError = nil
        stopStreaming()
        do {
            try await client.unregister()
        } catch {
            lastActionError = error.localizedDescription
        }
        refresh()
    }

    public func startStreaming() {
        guard streamTask == nil, let connection = client.makeConnection() else { return }
        let stream = connection.activate()
        streamTask = Task { [weak self] in
            self?.handshake = await connection.handshake()
            connection.startStream(intervalMs: 100)
            for await sample in stream {
                guard let self, !Task.isCancelled else { break }
                self.latestSample = sample
                self.samplesReceived += 1
            }
            connection.stopAndInvalidate()
        }
    }

    public func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }
}
