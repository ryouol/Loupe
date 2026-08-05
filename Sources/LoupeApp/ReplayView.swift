import Charts
import LoupeCore
import SwiftUI

/// Deliberately minimal fixture viewer backing `make replay`: proves the
/// whole chain (fixture → replay sources → decoded models → UI) end to end.
/// The real results and timeline views land in M1.5/M2.2.
public struct ReplayView: View {
    @State private var model: ReplayViewModel

    public init(basePath: String) {
        _model = State(initialValue: ReplayViewModel(basePath: basePath))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isLoaded {
                // System-wide and per-process series live in visibly separate
                // bands — an architecture rule, not a styling choice.
                systemBand
                processBand
                milestoneList
            } else if let failure = model.loadFailure {
                ContentUnavailableView(
                    "Fixture failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else {
                ProgressView("Loading fixture…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Replay — \(URL(fileURLWithPath: model.basePath).lastPathComponent)")
                .font(.title2).bold()
            Text(model.summary).foregroundStyle(.secondary).font(.callout)
            if !model.thermalStatesSeen.isEmpty {
                Text(
                    "Thermal states: "
                        + model.thermalStatesSeen.map(\.rawValue).joined(separator: " → ")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var systemBand: some View {
        GroupBox("System-wide") {
            Chart(model.chartPoints) { point in
                LineMark(
                    x: .value("Seconds", point.seconds),
                    y: .value("GB", point.systemUsedGB)
                )
                .foregroundStyle(by: .value("Series", "Memory used"))
                LineMark(
                    x: .value("Seconds", point.seconds),
                    y: .value("GB", point.swapUsedGB)
                )
                .foregroundStyle(by: .value("Series", "Swap used"))
            }
            .chartYAxisLabel("GB")
            .frame(height: 140)
        }
    }

    private var processBand: some View {
        GroupBox("Observed process") {
            Chart(model.chartPoints.filter { $0.processRSSGB != nil }) { point in
                LineMark(
                    x: .value("Seconds", point.seconds),
                    y: .value("GB", point.processRSSGB ?? 0)
                )
                .foregroundStyle(by: .value("Series", "RSS"))
            }
            .chartYAxisLabel("GB")
            .frame(height: 120)
        }
    }

    private var milestoneList: some View {
        GroupBox("Events (decode ticks collapsed: \(model.decodeTickCount))") {
            List(model.milestones) { milestone in
                HStack(spacing: 12) {
                    Text(String(format: "%8.3fs", milestone.offsetSeconds))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(milestone.kind.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 150, alignment: .leading)
                    if let requestId = milestone.requestId {
                        Text(requestId)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                    }
                    Text(milestone.detail).lineLimit(1).truncationMode(.tail)
                    Spacer()
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 180)
        }
    }
}
