import Charts
import LoupeCore
import SwiftUI

/// Session tab: empty state until a session is opened, then the correlated
/// timeline. Accepts drops of either file of a session pair.
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

/// The correlated timeline: phase swimlanes and telemetry lanes sharing one
/// x-domain and one scrubber. Y-axes are hidden by design — identical plot
/// widths are what keep a shared scrubber honest — so values read from the
/// scrub readout bar. System-wide and per-process series live in visually
/// distinct bands: that separation is a correctness requirement.
public struct ReplayView: View {
    @State private var model: ReplayViewModel

    public init(basePath: String) {
        _model = State(initialValue: ReplayViewModel(basePath: basePath))
    }

    public var body: some View {
        Group {
            if model.isLoaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        readoutBar
                        swimlaneBand
                        systemBand
                        if !model.gpuChartPoints.isEmpty {
                            gpuBand
                        }
                        processBand
                        requestTable
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
                value: String(format: "%.1f s", model.durationSeconds), label: "duration",
                symbol: "clock")
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

    // MARK: - Scrub readout

    private var readoutBar: some View {
        let readout = model.scrubSeconds.flatMap { model.readout(at: $0) }
        return HStack(spacing: 16) {
            Image(systemName: "scope")
                .foregroundStyle(readout == nil ? .secondary : Color.accentColor)
            if let readout {
                Text(String(format: "t = %.2f s", readout.seconds)).monospacedDigit().bold()
                readoutValue("memory", String(format: "%.2f GB", readout.systemUsedGB))
                readoutValue("swap", String(format: "%.2f GB", readout.swapUsedGB))
                if let rss = readout.processRSSGB {
                    readoutValue("rss", String(format: "%.2f GB", rss))
                }
                if let gpu = readout.gpuBusyPercent {
                    readoutValue("gpu", String(format: "%.0f%%", gpu))
                }
                readoutValue("request", readout.activeRequestId ?? "—")
                Spacer()
                Button("Clear") { model.scrubSeconds = nil }
                    .controlSize(.small)
            } else {
                Text("Drag across any lane to scrub the timeline")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func readoutValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Text(value).monospacedDigit()
        }
    }

    // MARK: - Lanes

    private var xDomain: ClosedRange<Double> { 0...max(model.durationSeconds, 0.001) }

    private var swimlaneBand: some View {
        GroupBox {
            Chart {
                ForEach(model.requestSpans) { span in
                    BarMark(
                        xStart: .value("s", span.startSeconds),
                        xEnd: .value("s", span.prefillEndSeconds),
                        y: .value("lane", span.lane),
                        height: .fixed(12)
                    )
                    .foregroundStyle(by: .value("Phase", "prefill"))
                    BarMark(
                        xStart: .value("s", span.prefillEndSeconds),
                        xEnd: .value("s", span.endSeconds),
                        y: .value("lane", span.lane),
                        height: .fixed(12)
                    )
                    .foregroundStyle(by: .value("Phase", "decode"))
                }
                scrubMark
            }
            .chartForegroundStyleScale(["prefill": Color.orange, "decode": Color.blue])
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: max(44, CGFloat(28 + (model.requestSpans.map(\.lane).max() ?? 0) * 16)))
            .chartOverlay { proxy in scrubSurface(proxy) }
        } label: {
            Label("Inference Phases", systemImage: "waveform.path.ecg")
        }
    }

    private var systemBand: some View {
        GroupBox {
            Chart {
                ForEach(model.chartPoints) { point in
                    AreaMark(
                        x: .value("s", point.seconds),
                        y: .value("GB", point.systemUsedGB)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue.opacity(0.25), .clear],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("GB", point.systemUsedGB),
                        series: .value("Series", "Memory used")
                    )
                    .foregroundStyle(by: .value("Series", "Memory used"))
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("GB", point.swapUsedGB),
                        series: .value("Series", "Swap used")
                    )
                    .foregroundStyle(by: .value("Series", "Swap used"))
                }
                scrubMark
            }
            .chartForegroundStyleScale(["Memory used": Color.blue, "Swap used": Color.orange])
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 120)
            .chartOverlay { proxy in scrubSurface(proxy) }
        } label: {
            Label("System-Wide — memory & swap", systemImage: "desktopcomputer")
        }
        .backgroundStyle(.blue.opacity(0.05))
    }

    private var gpuBand: some View {
        GroupBox {
            Chart {
                ForEach(model.gpuChartPoints) { point in
                    if let busy = point.gpuBusyPercent {
                        LineMark(
                            x: .value("s", point.seconds),
                            y: .value("v", busy),
                            series: .value("Series", "GPU busy %")
                        )
                        .foregroundStyle(by: .value("Series", "GPU busy %"))
                    }
                    if let watts = point.packagePowerWatts {
                        LineMark(
                            x: .value("s", point.seconds),
                            y: .value("v", watts),
                            series: .value("Series", "Package W")
                        )
                        .foregroundStyle(by: .value("Series", "Package W"))
                    }
                }
                scrubMark
            }
            .chartForegroundStyleScale(["GPU busy %": Color.green, "Package W": Color.red])
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 110)
            .chartOverlay { proxy in scrubSurface(proxy) }
        } label: {
            Label("System-Wide — GPU & power", systemImage: "bolt")
        }
        .backgroundStyle(.blue.opacity(0.05))
    }

    private var processBand: some View {
        GroupBox {
            Chart {
                ForEach(model.processChartPoints) { point in
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("GB", point.processRSSGB ?? 0)
                    )
                    .foregroundStyle(.purple)
                }
                scrubMark
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: xDomain)
            .frame(height: 110)
            .chartOverlay { proxy in scrubSurface(proxy) }
        } label: {
            Label("Observed Process — RSS", systemImage: "app.badge")
        }
        .backgroundStyle(.purple.opacity(0.06))
    }

    @ChartContentBuilder
    private var scrubMark: some ChartContent {
        if let scrub = model.scrubSeconds {
            RuleMark(x: .value("scrub", scrub))
                .foregroundStyle(.primary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    /// One gesture surface per lane, all writing the same scrub value — the
    /// alignment guarantee lives in the shared model, not per-view state.
    private func scrubSurface(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotAnchor = proxy.plotFrame else { return }
                            let plot = geo[plotAnchor]
                            let x = value.location.x - plot.origin.x
                            if let seconds: Double = proxy.value(atX: x) {
                                model.scrubSeconds = min(
                                    max(0, seconds), model.durationSeconds)
                            }
                        }
                )
        }
    }

    // MARK: - Tables

    private var requestTable: some View {
        GroupBox {
            Table(model.requestMetrics) {
                TableColumn("Request") { metrics in
                    Text(metrics.requestId).monospaced()
                }
                .width(70)
                TableColumn("Prompt") { metrics in
                    Text("\(metrics.promptTokens)").monospacedDigit()
                }
                .width(70)
                TableColumn("Output") { metrics in
                    Text("\(metrics.outputTokens)").monospacedDigit()
                }
                .width(70)
                TableColumn("TTFT") { metrics in
                    Text(String(format: "%.1f ms", metrics.ttftMs)).monospacedDigit()
                }
                .width(90)
                TableColumn("Decode") { metrics in
                    Text(String(format: "%.1f tok/s", metrics.decodeTokensPerSecond))
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 120, idealHeight: 160)
        } label: {
            Label("Requests — \(model.requestMetrics.count)", systemImage: "list.number")
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
            .frame(minHeight: 200)
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
