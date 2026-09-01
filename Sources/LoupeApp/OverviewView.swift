import LoupeCore
import LoupeSampler
import SwiftUI

struct OverviewView: View {
    let daemonModel: DaemonViewModel
    let onStartRecording: () -> Void
    let onOpenSample: () -> Void
    let onOpenSession: () -> Void
    let onShowDaemon: () -> Void

    // Process-constant; read the sysctls once, not per view rebuild.
    private static let host = HostInfo.fingerprint()
    private var host: HostFingerprint { Self.host }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        machineCard
                        statusCard
                    }
                    VStack(spacing: 16) {
                        machineCard
                        statusCard
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationSubtitle("Profiler for local AI inference")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Understand local inference, request by request")
                        .font(.largeTitle.weight(.semibold))
                    Text(
                        "Loupe correlates runtime milestones with process and system telemetry "
                            + "on one inspectable timeline. Data stays on this Mac."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button(action: onStartRecording) {
                    Label("Start recording", systemImage: "record.circle")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button(action: onOpenSample) {
                    Label("Open sample session", systemImage: "play.rectangle")
                }
                .controlSize(.large)
                Button(action: onOpenSession) {
                    Label("Import session…", systemImage: "folder")
                }
                .controlSize(.large)
            }
            Button(action: onShowDaemon) {
                Label("Optional GPU and power helper", systemImage: "bolt.shield")
            }
            .buttonStyle(.link)
        }
        .accessibilityElement(children: .contain)
    }

    private var machineCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                row("cpu", host.chip)
                row("memorychip", "\(formattedBytes(host.memoryBytes)) unified memory")
                row("square.grid.2x2", coreSummary)
                row("macwindow", "\(host.osVersion) (\(host.osBuild))")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("This Mac", systemImage: "desktopcomputer")
        }
    }

    private var coreSummary: String {
        guard host.performanceCores > 0 || host.efficiencyCores > 0 else {
            return "Core topology unavailable"
        }
        return "\(host.performanceCores) performance + \(host.efficiencyCores) efficiency cores"
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                DaemonStatusIndicator(status: daemonModel.status, label: daemonModel.statusLabel)
                Text(
                    daemonModel.isObservedMode
                        ? "Local recording captures memory, thermal state, and observed-process "
                            + "CPU/RSS. The optional helper adds GPU and power where supported."
                        : "The approved helper is available for GPU and power telemetry."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Telemetry", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text)
        }
        .font(.callout)
    }
}
