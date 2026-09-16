import Charts
import LoupeCore
import SwiftUI
import UniformTypeIdentifiers

/// Session tab: empty state until a session is opened, then the correlated
/// timeline. Accepts drops of either file of a session pair.
struct SessionScreen: View {
    @Binding var basePath: String?
    let onOpen: () -> Void
    let onOpenSample: () -> Void

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
                    Button("Open sample session", action: onOpenSample)
                        .buttonStyle(.borderedProminent)
                    Button("Import session…", action: onOpen)
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
    @State private var exportDocument: TextExportDocument?
    @State private var exportType: UTType = .json
    @State private var exportFailure: String?

    public init(basePath: String) {
        _model = State(initialValue: ReplayViewModel(basePath: basePath))
    }

    public var body: some View {
        Group {
            if model.isLoaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        ScrubReadoutBar(model: model)
                        swimlaneBand
                        if !model.annotations.isEmpty {
                            annotationList
                        }
                        systemBand
                        if !model.gpuChartPoints.isEmpty {
                            gpuBand
                        }
                        if !model.gpuPowerChartPoints.isEmpty
                            || !model.packagePowerChartPoints.isEmpty
                        {
                            powerBand
                        }
                        if model.processChartPoints.contains(where: { $0.processRSSGB != nil }) {
                            processMemoryBand
                        }
                        if model.processChartPoints.contains(where: {
                            $0.processCPUPercent != nil
                        }) {
                            processCPUBand
                        }
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
        .toolbar {
            Button("Export evidence JSON", systemImage: "curlybraces") {
                exportEvidence(as: .json)
            }
            .disabled(!model.isLoaded)
            Button("Export evidence CSV", systemImage: "tablecells") {
                exportEvidence(as: .commaSeparatedText)
            }
            .disabled(!model.isLoaded)
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "\(model.session.name)-evidence"
        ) { result in
            if case .failure(let error) = result {
                exportFailure = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert(
            "Evidence export failed",
            isPresented: Binding(
                get: { exportFailure != nil },
                set: { if !$0 { exportFailure = nil } })
        ) {
            Button("OK", role: .cancel) { exportFailure = nil }
        } message: {
            Text(exportFailure ?? "Unknown export error")
        }
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
                value: model.acquisitionLossDisplay, label: "acquisition loss",
                symbol: model.acquisitionLossDisplay == "0"
                    ? "checkmark.seal" : "exclamationmark.triangle",
                tint: model.acquisitionLossDisplay == "0" ? .green : .orange)
            StatChip(
                value: "\(model.sampleDrops + model.eventDrops)", label: "replay parser",
                symbol: model.sampleDrops + model.eventDrops == 0
                    ? "checkmark.seal" : "exclamationmark.triangle",
                tint: model.sampleDrops + model.eventDrops == 0 ? .green : .red)
            StatChip(
                value: model.thermalStatesSeen.map(\.rawValue).joined(separator: " → "),
                label: "thermal", symbol: "thermometer.medium")
        }
    }

    private func exportEvidence(as type: UTType) {
        exportType = type
        do {
            let data =
                type == .json
                ? try model.evidenceJSON()
                : Data(try model.evidenceCSV().utf8)
            exportDocument = TextExportDocument(data: data)
        } catch {
            exportFailure = error.localizedDescription
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
                ForEach(model.annotations) { annotation in
                    RuleMark(x: .value("s", annotation.atSeconds))
                        .foregroundStyle(.red.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(["prefill": Color.orange, "decode": Color.blue])
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: max(44, CGFloat(28 + (model.requestSpans.map(\.lane).max() ?? 0) * 16)))
            .chartOverlay { proxy in ScrubOverlay(model: model, proxy: proxy) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Inference phase timeline")
            .accessibilityValue("\(model.requestSpans.count) completed requests")
        } label: {
            Label("Inference Phases", systemImage: "waveform.path.ecg")
        }
    }

    private var annotationList: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.annotations) { annotation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: annotation.kind))
                            .foregroundStyle(.red)
                            .frame(width: 18)
                        Text(String(format: "%.2f s", annotation.atSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Text(annotation.message)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        // The link to the moment: jumping scrubs every lane.
                        Button("Jump") { model.scrubSeconds = annotation.atSeconds }
                            .controlSize(.small)
                            .help(
                                "Evidence: \(annotation.evidence.sampleTimestamps.count) samples, "
                                    + "\(annotation.evidence.eventTimestamps.count) events")
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Findings (\(model.annotations.count))", systemImage: "exclamationmark.bubble")
        }
    }

    private func symbol(for kind: Annotation.Kind) -> String {
        switch kind {
        case .thermalThrottling: return "thermometer.high"
        case .memoryPressure: return "memorychip"
        case .prefillQueueing: return "hourglass"
        case .kvDominatedFootprint: return "square.stack.3d.up.fill"
        case .gpuUnderutilized: return "bolt.slash"
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
            }
            .chartForegroundStyleScale(["Memory used": Color.blue, "Swap used": Color.orange])
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 120)
            .chartOverlay { proxy in ScrubOverlay(model: model, proxy: proxy) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("System memory and swap timeline")
            .accessibilityValue(model.memoryAccessibilitySummary)
        } label: {
            Label("System-wide: memory and swap", systemImage: "desktopcomputer")
        }
        .backgroundStyle(.blue.opacity(0.05))
    }

    private var gpuBand: some View {
        GroupBox {
            Chart {
                ForEach(model.gpuChartPoints) { point in
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("GPU busy %", point.gpuBusyPercent ?? 0)
                    )
                    .foregroundStyle(.green)
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 110)
            .chartOverlay { proxy in ScrubOverlay(model: model, proxy: proxy) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("GPU utilization timeline in percent")
            .accessibilityValue(model.gpuUtilizationAccessibilitySummary)
        } label: {
            Label(
                "System-wide: GPU utilization (%)", systemImage: "gauge.with.dots.needle.50percent")
        }
        .backgroundStyle(.blue.opacity(0.05))
    }

    private var powerBand: some View {
        GroupBox {
            Chart {
                ForEach(model.gpuPowerChartPoints) { point in
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("W", point.gpuPowerWatts ?? 0),
                        series: .value("Series", "GPU power")
                    )
                    .foregroundStyle(by: .value("Series", "GPU power"))
                }
                ForEach(model.packagePowerChartPoints) { point in
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("W", point.packagePowerWatts ?? 0),
                        series: .value("Series", "Package power")
                    )
                    .foregroundStyle(by: .value("Series", "Package power"))
                }
            }
            .chartForegroundStyleScale([
                "GPU power": Color.orange, "Package power": Color.red,
            ])
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 110)
            .chartOverlay { proxy in ScrubOverlay(model: model, proxy: proxy) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("System power timeline in watts")
            .accessibilityValue(model.powerAccessibilitySummary)
        } label: {
            Label("System-wide: power (W)", systemImage: "bolt")
        }
        .backgroundStyle(.orange.opacity(0.06))
    }

    private var processMemoryBand: some View {
        GroupBox {
            Chart {
                ForEach(model.processChartPoints) { point in
                    LineMark(
                        x: .value("s", point.seconds),
                        y: .value("GB", point.processRSSGB ?? 0)
                    )
                    .foregroundStyle(.purple)
                }
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: xDomain)
            .frame(height: 110)
            .chartOverlay { proxy in ScrubOverlay(model: model, proxy: proxy) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Observed process memory timeline")
            .accessibilityValue(model.processMemoryAccessibilitySummary)
        } label: {
            Label("Observed process: RSS", systemImage: "app.badge")
        }
        .backgroundStyle(.purple.opacity(0.06))
    }

    private var processCPUBand: some View {
        GroupBox {
            Chart {
                ForEach(model.processChartPoints) { point in
                    if let cpu = point.processCPUPercent {
                        LineMark(
                            x: .value("s", point.seconds),
                            y: .value("CPU %", cpu)
                        )
                        .foregroundStyle(.teal)
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: xDomain)
            .frame(height: 110)
            .chartOverlay { proxy in ScrubOverlay(model: model, proxy: proxy) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Observed process CPU timeline in percent")
            .accessibilityValue(model.processCPUAccessibilitySummary)
        } label: {
            Label("Observed process: CPU (%)", systemImage: "cpu")
        }
        .backgroundStyle(.teal.opacity(0.06))
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
                TableColumn("Status") { metrics in
                    Text(
                        model.requestOutcomeByID[metrics.requestId]?
                            .finishReason ?? "unknown")
                }
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
            Label("Requests (\(model.requestMetrics.count))", systemImage: "list.number")
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
                    Text(milestone.requestId ?? "None")
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
                "Events (\(model.decodeTickCount) decode ticks collapsed)",
                systemImage: "list.bullet.rectangle")
        }
    }
}

/// The two views that read `scrubSeconds` — and the only two. Everything
/// else in the timeline is invalidated once per load, so per-frame drags
/// never rebuild four charts of marks.
private struct ScrubReadoutBar: View {
    let model: ReplayViewModel

    var body: some View {
        let readout = model.scrubSeconds.flatMap { model.readout(at: $0) }
        HStack(spacing: 16) {
            Image(systemName: "scope")
                .foregroundStyle(readout == nil ? .secondary : Color.accentColor)
            if let readout {
                Text(String(format: "t = %.2f s", readout.seconds)).monospacedDigit().bold()
                value("memory", String(format: "%.2f GB", readout.systemUsedGB))
                value("swap", String(format: "%.2f GB", readout.swapUsedGB))
                if let rss = readout.processRSSGB {
                    value("rss", String(format: "%.2f GB", rss))
                }
                if let gpu = readout.gpuBusyPercent {
                    value("gpu", String(format: "%.0f%%", gpu))
                }
                if let cpu = readout.processCPUPercent {
                    value("cpu", String(format: "%.0f%%", cpu))
                }
                if let watts = readout.gpuPowerWatts {
                    value("gpu power", String(format: "%.2f W", watts))
                }
                if let watts = readout.packagePowerWatts {
                    value("package", String(format: "%.2f W", watts))
                }
                value("request", readout.activeRequestId ?? "None")
                Spacer()
                Button {
                    moveScrubber(by: -0.1)
                } label: {
                    Label("Move scrubber back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("[", modifiers: [])
                Button {
                    moveScrubber(by: 0.1)
                } label: {
                    Label("Move scrubber forward", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("]", modifiers: [])
                Button("Clear") { model.scrubSeconds = nil }
                    .controlSize(.small)
            } else {
                Text("Drag across any lane to scrub the timeline")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start scrubber") { model.scrubSeconds = 0 }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func moveScrubber(by delta: Double) {
        model.scrubSeconds = min(max(0, (model.scrubSeconds ?? 0) + delta), model.durationSeconds)
    }

    private func value(_ label: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Text(text).monospacedDigit()
        }
    }
}

/// Cursor + gesture for one lane. Every lane's overlay writes the same
/// model value, which is what keeps the lanes aligned by construction.
private struct ScrubOverlay: View {
    let model: ReplayViewModel
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let scrub = model.scrubSeconds,
                    let plotAnchor = proxy.plotFrame,
                    let x = proxy.position(forX: scrub)
                {
                    let plot = geo[plotAnchor]
                    Path { path in
                        path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                        path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                    }
                    .stroke(.primary.opacity(0.6), lineWidth: 1)
                }
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
        .accessibilityHidden(true)
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
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
