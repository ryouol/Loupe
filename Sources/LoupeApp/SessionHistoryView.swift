import LoupeStore
import SwiftUI

public struct SessionHistoryView: View {
    let model: RecordingViewModel
    let onOpen: (SessionSummary) -> Void
    let onOpenSample: () -> Void
    @State private var pendingDeletion: SessionSummary?

    public init(
        model: RecordingViewModel,
        onOpen: @escaping (SessionSummary) -> Void,
        onOpenSample: @escaping () -> Void
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onOpenSample = onOpenSample
    }

    public var body: some View {
        Group {
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Recorded Sessions", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Completed recordings appear here and remain available across launches.")
                } actions: {
                    Button(
                        "Open sample session", systemImage: "play.rectangle", action: onOpenSample
                    )
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(model.sessions) { session in
                    sessionRow(session)
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Session history")
        .toolbar {
            Button("Open sample session", systemImage: "play.rectangle", action: onOpenSample)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshHistory() }
            }
        }
        .task { await model.refreshHistory() }
        .alert(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let session = pendingDeletion {
                    Task { await model.delete(session) }
                }
                pendingDeletion = nil
            }
        } message: {
            Text(
                "The database, history manifest, portable evidence pair, and acquisition metadata will be removed from this Mac."
            )
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.displayName).font(.headline)
                    SessionStateBadge(state: session.state)
                }
                Text(session.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(session.eventCount) events · \(session.sampleCount) samples")
                    .font(.callout)
                    .monospacedDigit()
                Text("Acquisition loss: \(acquisitionLoss(session))")
                    .font(.caption)
                    .foregroundStyle(
                        acquisitionLoss(session) == "0" ? Color.secondary : Color.orange)
                Text(session.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                let noteworthy = session.transitions.filter {
                    [.denied, .degraded, .adapterDisconnected, .reconnecting].contains($0.state)
                }
                if !noteworthy.isEmpty {
                    Text(noteworthy.map { $0.state.displayName }.joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Open") { onOpen(session) }
                .buttonStyle(.borderedProminent)
                .disabled(!session.isReplayAvailable)
                .help(
                    session.isReplayAvailable
                        ? "Open the correlated timeline"
                        : "Portable evidence is unavailable for this interrupted session")
            Button {
                pendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(
                model.isBusy
                    || (model.isActive && model.current?.storageID == session.storageID)
            )
            .help("Delete this local session")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func acquisitionLoss(_ session: SessionSummary) -> String {
        guard let metadata = session.acquisitionMetadata else { return "unknown" }
        if let events = metadata.eventLosses.exact,
            let telemetry = metadata.telemetryLosses.exact
        {
            return String(events > Int.max - telemetry ? Int.max : events + telemetry)
        }
        let lower =
            metadata.eventLosses.lowerBound > Int.max
                - metadata.telemetryLosses.lowerBound
            ? Int.max
            : metadata.eventLosses.lowerBound + metadata.telemetryLosses.lowerBound
        return lower == 0 ? "unknown" : "≥\(lower) · unknown total"
    }
}
