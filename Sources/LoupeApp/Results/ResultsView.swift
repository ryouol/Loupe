import Charts
import LoupeBench
import SwiftUI
import UniformTypeIdentifiers

/// Benchmark report browser: run list, per-run summaries, and the context
/// sweep with error bars (p50 point, ±stddev whiskers — never a bare mean).
public struct ResultsView: View {
    @State private var model = ResultsViewModel()
    @State private var isImporting = false

    public init() {}

    public var body: some View {
        Group {
            if let report = model.report {
                loaded(report: report)
            } else if let failure = model.loadFailure {
                ContentUnavailableView(
                    "Report Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else {
                ContentUnavailableView {
                    Label("No Benchmark Report Open", systemImage: "chart.bar.doc.horizontal")
                } description: {
                    Text("Open a report produced by `make bench`, or drop one here.")
                } actions: {
                    Button("Open Report…") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationSubtitle(model.reportName.isEmpty ? "Benchmarks" : model.reportName)
        .toolbar {
            Button("Open Report…", systemImage: "folder") { isImporting = true }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                model.load(url: url)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url: url)
            return true
        }
    }

    private func loaded(report: BenchmarkReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(report: report)
                sweepCharts
                runTable
            }
            .padding(20)
        }
    }

    private func header(report: BenchmarkReport) -> some View {
        HStack(spacing: 10) {
            StatChip(
                value: URL(fileURLWithPath: report.spec.model).lastPathComponent,
                label: "model", symbol: "shippingbox")
            StatChip(
                value: report.spec.quantization, label: "quantization",
                symbol: "square.stack.3d.down.right")
            StatChip(
                value: report.spec.contexts.map(String.init).joined(separator: " / "),
                label: "contexts", symbol: "text.alignleft")
            StatChip(
                value: "\(report.spec.repeats)× + \(report.spec.warmup) warmup",
                label: "repeats", symbol: "repeat")
            StatChip(value: report.host.chip, label: "chip", symbol: "cpu")
        }
    }

    private var sweepCharts: some View {
        VStack(alignment: .leading, spacing: 16) {
            sweepChart(
                title: "Decode Rate vs Context", symbol: "speedometer",
                unit: "decode tok/s (p50 ± σ)", tint: .teal, metric: \.decode)
            sweepChart(
                title: "Time to First Token vs Context", symbol: "timer",
                unit: "TTFT ms (p50 ± σ)", tint: .indigo, metric: \.ttft)
        }
    }

    private func sweepChart(
        title: String, symbol: String, unit: String, tint: Color,
        metric: KeyPath<ResultsViewModel.SweepPoint, DistributionSummary>
    ) -> some View {
        GroupBox {
            Chart(model.sweep) { point in
                let summary = point[keyPath: metric]
                RuleMark(
                    x: .value("Context", "\(point.contextTokens)"),
                    yStart: .value("v", summary.p50 - summary.stddev),
                    yEnd: .value("v", summary.p50 + summary.stddev)
                )
                .foregroundStyle(tint.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                PointMark(
                    x: .value("Context", "\(point.contextTokens)"),
                    y: .value("v", summary.p50)
                )
                .foregroundStyle(tint)
                LineMark(
                    x: .value("Context", "\(point.contextTokens)"),
                    y: .value("v", summary.p50)
                )
                .foregroundStyle(tint.opacity(0.4))
            }
            .chartYAxisLabel(unit)
            .chartXAxisLabel("context tokens")
            .frame(height: 180)
            .padding(.top, 4)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var runTable: some View {
        GroupBox {
            Table(model.runRows) {
                TableColumn("Context") { row in
                    Text("\(row.contextTokens)").monospacedDigit()
                }
                .width(80)
                TableColumn("Run") { row in
                    Text("#\(row.runIndex + 1)").foregroundStyle(.secondary)
                }
                .width(50)
                TableColumn("TTFT") { row in
                    Text(String(format: "%.1f ms", row.ttftMs)).monospacedDigit()
                }
                .width(100)
                TableColumn("Decode") { row in
                    Text(String(format: "%.1f tok/s", row.decodeTokensPerSecond)).monospacedDigit()
                }
                .width(110)
                TableColumn("Tokens") { row in
                    Text("\(row.outputTokens)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 180)
        } label: {
            Label("Measured Runs", systemImage: "list.number")
        }
    }
}
