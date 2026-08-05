import LoupeCore
import SwiftUI

struct DaemonStatusIndicator: View {
    let status: DaemonStatus
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status == .enabled ? Color.green : .orange)
                .frame(width: 9, height: 9)
            Text(label)
        }
    }
}

public struct DaemonView: View {
    @State private var model: DaemonViewModel

    public init(model: DaemonViewModel = DaemonViewModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Form {
            if model.isObservedMode {
                Section {
                    Label {
                        Text(
                            "Running in observed mode. GPU and power channels need the "
                                + "privileged daemon.")
                    } icon: {
                        Image(systemName: "eye")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                LabeledContent("Status") {
                    DaemonStatusIndicator(status: model.status, label: model.statusLabel)
                }
                if let error = model.lastActionError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Install…") { model.install() }
                        .disabled(model.status == .enabled)
                    Button("Uninstall") { Task { await model.uninstall() } }
                        .disabled(model.status == .notRegistered)
                    Spacer()
                    Button("Refresh") { model.refresh() }
                }
            } header: {
                Text("Privileged Daemon")
            } footer: {
                Text(
                    "The daemon reads GPU, ANE, and package power via IOReport. macOS asks "
                        + "for approval in System Settings › Login Items the first time.")
            }

            if model.status == .enabled {
                Section("Live Telemetry") {
                    if let handshake = model.handshake {
                        LabeledContent(
                            "Daemon",
                            value:
                                "v\(handshake.daemonVersion) · protocol v\(handshake.protocolVersion) · pid \(handshake.pid)"
                        )
                    }
                    LabeledContent("Samples received", value: "\(model.samplesReceived)")
                    if let sample = model.latestSample {
                        LabeledContent(
                            "Thermal state", value: sample.system.thermalState.rawValue)
                        LabeledContent(
                            "Memory used", value: formattedBytes(sample.system.memoryUsedBytes))
                        LabeledContent(
                            "Swap used", value: formattedBytes(sample.system.swapUsedBytes))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle("Privileged telemetry")
        .task {
            model.refresh()
            model.startStreaming()
        }
        .onDisappear { model.stopStreaming() }
    }
}
