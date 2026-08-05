import LoupeCore
import LoupeSampler
import SwiftUI

struct OverviewView: View {
    let daemonModel: DaemonViewModel
    let sessionName: String?
    let onOpenSession: () -> Void
    let onShowDaemon: () -> Void

    // Process-constant; read the sysctls once, not per view rebuild.
    private static let host = HostInfo.fingerprint()
    private var host: HostFingerprint { Self.host }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                HStack(alignment: .top, spacing: 16) {
                    machineCard
                    statusCard
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
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Loupe")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Correlate system telemetry with inference events on one timeline.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: onOpenSession) {
                    Label(
                        sessionName.map { "Session: \($0)" } ?? "Open Session…",
                        systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button(action: onShowDaemon) {
                    Label("Set Up Daemon", systemImage: "bolt.shield")
                }
                .controlSize(.large)
            }
            .padding(.top, 6)
        }
        .padding(.top, 16)
    }

    private var machineCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                row("cpu", host.chip)
                row("memorychip", "\(formattedBytes(host.memoryBytes)) unified memory")
                row(
                    "square.grid.2x2",
                    "\(host.performanceCores) performance + \(host.efficiencyCores) efficiency cores"
                )
                row("macwindow", "\(host.osVersion) (\(host.osBuild))")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("This Mac", systemImage: "desktopcomputer")
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                DaemonStatusIndicator(status: daemonModel.status, label: daemonModel.statusLabel)
                Text(
                    daemonModel.isObservedMode
                        ? "Observed mode: CPU, memory, swap, and thermal state only. "
                            + "Install the daemon to unlock GPU and power channels."
                        : "Full telemetry available."
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
