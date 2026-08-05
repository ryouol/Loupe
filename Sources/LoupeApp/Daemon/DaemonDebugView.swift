import LoupeCore
import SwiftUI

/// M0.6 debug surface: install/uninstall, live status, and the 10 Hz sample
/// readout when connected. Replaced by real monitoring UI in M5.
public struct DaemonDebugView: View {
    @State private var model: DaemonViewModel

    public init(model: DaemonViewModel = DaemonViewModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isObservedMode {
                observedBanner
            }
            GroupBox("Privileged daemon") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(model.status == .enabled ? .green : .orange)
                        .frame(width: 10, height: 10)
                    Text(model.statusLabel)
                    Spacer()
                    Button("Install") { model.install() }
                        .disabled(model.status == .enabled)
                    Button("Uninstall") { Task { await model.uninstall() } }
                        .disabled(model.status == .notRegistered)
                    Button("Refresh") { model.refresh() }
                }
                if let error = model.lastActionError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            if model.status == .enabled {
                GroupBox("Live stream") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let handshake = model.handshake {
                            Text(
                                "daemon v\(handshake.daemonVersion) · protocol v\(handshake.protocolVersion) · pid \(handshake.pid)"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        Text("Samples received: \(model.samplesReceived)")
                        if let sample = model.latestSample {
                            Text(
                                "thermal \(sample.system.thermalState.rawValue) · used \(sample.system.memoryUsedBytes / 1_000_000) MB · swap \(sample.system.swapUsedBytes / 1_000_000) MB"
                            )
                            .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Button("Start stream") { model.startStreaming() }
                            Button("Stop") { model.stopStreaming() }
                        }
                    }
                }
            }
        }
        .task { model.refresh() }
    }

    private var observedBanner: some View {
        Label {
            Text(
                "Daemon unavailable — running in observed mode. "
                    + "GPU and power channels need the privileged daemon.")
        } icon: {
            Image(systemName: "eye")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
