import Charts
import LoupeCore
import SwiftUI

/// Session tab: empty state until a session is opened, then the replay
/// detail. Accepts drops of either file of a session pair.
struct SessionScreen: View {
    @Binding var basePath: String?
    let onOpen: () -> Void

    var body: some View {
        Group {
            if let basePath {
                ReplayView(basePath: basePath)
                    .id(basePath)
            } else {
                ContentUnavailableView {
                    Label("No Session Open", systemImage: "waveform.magnifyingglass")
                } description: {
                    Text("Open a recorded session (.ndjson pair), or drop one here.")
                } actions: {
                    Button("Open Session…", action: onOpen)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            basePath = SessionFilePair(anyFileURL: url).basePath
            return true
        }
    }
}

public struct ReplayView: View {
    @State private var model: ReplayViewModel

    public init(basePath: String) {
        _model = State(initialValue: ReplayViewModel(basePath: basePath))
    }

    public var body: some View {
        Group {
            if model.isLoaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        systemBand
                        processBand
                        eventTable
                    }
                    .padding(20)
                }
            } else if let failure = model.loadFailure {
                ContentUnavailableView(
                    "Session Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(model.session.name)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatChip(
                value: "\(model.samples.count)", label: "samples", symbol: "waveform")
            StatChip(
                value: "\(model.totalEventCount)", label: "events",
                symbol: "list.bullet.rectangle")
            StatChip(
                value: "\(model.decodeTickCount)", label: "decode ticks", symbol: "cpu")
            StatChip(
                value: "\(model.sampleDrops + model.eventDrops)", label: "dropped",
                symbol: model.sampleDrops + model.eventDrops == 0
                    ? "checkmark.seal" : "exclamationmark.triangle",
                tint: model.sampleDrops + model.eventDrops == 0 ? .green : .red)
            StatChip(
                value: model.thermalStatesSeen.map(\.rawValue).joined(separator: " → "),
                label: "thermal", symbol: "thermometer.medium")
        }
    }

    /// System-wide and per-process series render in separate bands on
    /// purpose: the two signal families must never share an axis.
    private var systemBand: some View {
        GroupBox {
            Chart(model.chartPoints) { point in
                AreaMark(
                    x: .value("Time (s)", point.seconds),
                    y: .value("GB", point.systemUsedGB)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue.opacity(0.25), .clear],
                        startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("Time (s)", point.seconds),
                    y: .value("GB", point.systemUsedGB),
                    series: .value("Series", "Memory used")
                )
                .foregroundStyle(by: .value("Series", "Memory used"))
                LineMark(
                    x: .value("Time (s)", point.seconds),
                    y: .value("GB", point.swapUsedGB),
                    series: .value("Series", "Swap used")
                )
                .foregroundStyle(by: .value("Series", "Swap used"))
            }
            .chartForegroundStyleScale(["Memory used": Color.blue, "Swap used": Color.orange])
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("GB")
            .frame(height: 160)
            .padding(.top, 4)
        } label: {
            Label("System-Wide", systemImage: "desktopcomputer")
        }
    }

    private var processBand: some View {
        GroupBox {
            Chart(model.processChartPoints) { point in
                LineMark(
                    x: .value("Time (s)", point.seconds),
                    y: .value("GB", point.processRSSGB ?? 0)
                )
                .foregroundStyle(.purple)
            }
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("RSS GB")
            .frame(height: 130)
            .padding(.top, 4)
        } label: {
            Label("Observed Process", systemImage: "app.badge")
        }
    }

    private var eventTable: some View {
        GroupBox {
            Table(model.milestones) {
                TableColumn("Time") { milestone in
                    Text(String(format: "%.3f s", milestone.offsetSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Event") { milestone in
                    Text(milestone.kind.rawValue)
                        .font(.system(.body, design: .monospaced))
                }
                .width(150)
                TableColumn("Request") { milestone in
                    Text(milestone.requestId ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Detail") { milestone in
                    Text(milestone.detail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(milestone.detail)
                }
            }
            .frame(minHeight: 260)
        } label: {
            Label(
                "Events — \(model.decodeTickCount) decode ticks collapsed",
                systemImage: "list.bullet.rectangle")
        }
    }
}

struct StatChip: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
