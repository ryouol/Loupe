import Foundation
import LoupeCore
import LoupeSampler
import Observation

/// Install/approval state machine + live readout. Hard requirement: a denied
/// or missing daemon degrades to observed mode, never crashes or blocks.
@MainActor
@Observable
public final class DaemonViewModel {
    private let client: any DaemonServiceClient
    private var streamTask: Task<Void, Never>?
    private var activeConnection: DaemonXPCClient?
    private var streamGeneration = 0

    public private(set) var status: DaemonStatus
    public private(set) var lastActionError: String?
    public private(set) var latestSample: SystemSample?
    public private(set) var samplesReceived = 0
    public private(set) var handshake: DaemonHandshake?

    public init(client: any DaemonServiceClient = SMAppServiceDaemonClient()) {
        self.client = client
        self.status = client.status()
    }

    public var isObservedMode: Bool { status != .enabled }
    public var installationBlocker: String? { client.installationBlocker() }

    public var statusLabel: String {
        switch status {
        case .notRegistered: return "Not installed"
        case .requiresApproval: return "Waiting for approval in System Settings"
        case .enabled: return "Running"
        case .notFound: return "Helper missing from app bundle"
        case .unknown(let detail): return "Unknown status (\(detail))"
        }
    }

    /// Also (re)starts streaming when the daemon is reachable: approval can
    /// happen out-of-app in System Settings, so any status check may be the
    /// moment the connection first becomes possible.
    public func refresh() {
        status = client.status()
        if status == .enabled {
            startStreaming()
        } else {
            stopStreaming()
        }
    }

    public func install() {
        lastActionError = nil
        if let installationBlocker {
            lastActionError = installationBlocker
            return
        }
        do {
            try client.register()
        } catch {
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
        lastActionError = nil
        streamGeneration += 1
        let generation = streamGeneration
        activeConnection = connection
        let stream = connection.activate()
        streamTask = Task { [weak self] in
            guard let handshake = await connection.handshake(),
                handshake.protocolVersion == EventProtocol.version,
                !Task.isCancelled,
                self?.streamGeneration == generation
            else {
                if !Task.isCancelled, self?.streamGeneration == generation {
                    self?.lastActionError =
                        "The helper did not complete the protocol handshake; local mode remains available."
                }
                connection.stopAndInvalidate()
                self?.finishStreaming(generation: generation)
                return
            }
            self?.handshake = handshake
            connection.startStream()
            for await sample in stream {
                guard let self, !Task.isCancelled, streamGeneration == generation else { break }
                self.latestSample = sample
                self.samplesReceived += 1
            }
            connection.stopAndInvalidate()
            // Stream ended (daemon died or connection dropped): clear so a
            // later refresh can reconnect instead of being stuck forever.
            self?.finishStreaming(generation: generation)
        }
    }

    public func stopStreaming() {
        streamGeneration += 1
        activeConnection?.stopAndInvalidate()
        activeConnection = nil
        streamTask?.cancel()
        streamTask = nil
    }

    private func finishStreaming(generation: Int) {
        guard streamGeneration == generation else { return }
        activeConnection = nil
        streamTask = nil
    }
}
