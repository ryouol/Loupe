import LoupeStore
import SwiftUI

public struct RecordingView: View {
    let model: RecordingViewModel
    @State private var displayName = ""

    public init(model: RecordingViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let failure = model.setupFailure ?? model.lastError {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Recording error: \(failure)")
                }
                if let current = model.current {
                    statusCard(current)
                    if model.isActive {
                        adapterCard(current)
                    }
                    transitionCard(current)
                    if current.state.isTerminal {
                        readyCard
                    }
                } else {
                    readyCard
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationSubtitle("Local-first recording")
        .task { await model.observe() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Record a local inference run")
                    .font(.title2.weight(.semibold))
                Text("Runtime events and telemetry stay in your user account by default.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isActive {
                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    Task { await model.start(displayName: displayName) }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.setupFailure != nil)
            }
        }
    }

    private var readyCard: some View {
        GroupBox(model.current == nil ? "Session details" : "Next session") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Optional session name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Session name")
                Text(
                    model.current == nil
                        ? "Start recording first, then launch an instrumented MLX or llama.cpp "
                            + "run with the two environment values Loupe provides."
                        : "The completed session is in History. Name the next session here, "
                            + "then choose Start Recording."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private func statusCard(_ session: SessionSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SessionStateBadge(state: session.state)
                    Spacer()
                    Text("\(session.eventCount) events · \(session.sampleCount) samples")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(session.statusDetail)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.isActive ? 1 : 0)
                    .accessibilityHidden(!model.isActive)
            }
            .padding(6)
        } label: {
            Label(session.displayName, systemImage: "waveform.path.ecg")
        }
    }

    private func adapterCard(_ session: SessionSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Set these values in the same terminal before starting the instrumented run. "
                        + "The socket accepts only processes owned by your user."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                LabeledContent("LOUPE_SOCKET_PATH") {
                    Text(model.socketPath ?? "Unavailable")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("LOUPE_RUN_ID") {
                    Text(session.runID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy environment", systemImage: "doc.on.doc") {
                        model.copyAdapterEnvironment()
                    }
                    Spacer()
                    Text("No account, cloud service, or API key required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Label("Connect an adapter", systemImage: "terminal")
        }
    }

    private func transitionCard(_ session: SessionSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.transitions.enumerated()), id: \.offset) { _, transition in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(for: transition.state))
                            .foregroundStyle(color(for: transition.state))
                            .frame(width: 18)
                        Text(transition.state.displayName)
                            .frame(width: 150, alignment: .leading)
                        Text(transition.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(6)
        } label: {
            Label("Recording timeline", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private func symbol(for state: SessionLifecycleState) -> String {
        switch state {
        case .preparing: return "gearshape"
        case .waitingForAdapter: return "hourglass"
        case .recording: return "record.circle.fill"
        case .reconnecting: return "arrow.clockwise"
        case .adapterDisconnected: return "cable.connector.slash"
        case .degraded: return "exclamationmark.triangle"
        case .denied: return "hand.raised.fill"
        case .stopped: return "stop.circle.fill"
        case .failed, .interrupted: return "xmark.octagon.fill"
        }
    }

    private func color(for state: SessionLifecycleState) -> Color {
        switch state {
        case .recording: return .red
        case .stopped: return .green
        case .degraded, .adapterDisconnected, .reconnecting: return .orange
        case .denied, .failed, .interrupted: return .red
        case .preparing, .waitingForAdapter: return .secondary
        }
    }
}

struct SessionStateBadge: View {
    let state: SessionLifecycleState

    var body: some View {
        Text(state.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Session status: \(state.displayName)")
    }

    private var tint: Color {
        switch state {
        case .recording: return .red
        case .stopped: return .green
        case .failed, .denied, .interrupted: return .red
        case .degraded, .adapterDisconnected, .reconnecting: return .orange
        case .preparing, .waitingForAdapter: return .secondary
        }
    }
}

extension SessionLifecycleState {
    var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .waitingForAdapter: return "Waiting for adapter"
        case .recording: return "Recording"
        case .reconnecting: return "Reconnecting"
        case .adapterDisconnected: return "Adapter disconnected"
        case .degraded: return "Degraded"
        case .denied: return "Denied"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
}
