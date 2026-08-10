import LoupeBench
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ComparisonViewModel {
    public private(set) var baseline: (name: String, report: BenchmarkReport)?
    public private(set) var candidate: (name: String, report: BenchmarkReport)?
    public private(set) var loadFailure: String?

    public var comparison: RunComparison? {
        guard let baseline, let candidate else { return nil }
        return RunComparison.compare(baseline: baseline.report, candidate: candidate.report)
    }

    public init() {}

    public func load(url: URL, asBaseline: Bool) {
        do {
            let report = try BenchmarkAssembler.decode(Data(contentsOf: url))
            let entry = (url.deletingPathExtension().lastPathComponent, report)
            if asBaseline { baseline = entry } else { candidate = entry }
            loadFailure = nil
        } catch {
            loadFailure = "Cannot read report: \(error.localizedDescription)"
        }
    }

    public func exportCSV() -> String? {
        guard let comparison, let baseline, let candidate else { return nil }
        return ComparisonExport.csv(
            baselineName: baseline.name, candidateName: candidate.name, comparison: comparison)
    }

    public func exportJSON() -> Data? {
        guard let comparison, let baseline, let candidate else { return nil }
        return try? ComparisonExport.json(
            baselineName: baseline.name, candidateName: candidate.name, comparison: comparison)
    }
}

/// A/B benchmark comparison. Specs gate everything: a mismatch renders the
/// blocking banner with every differing dimension and no delta anywhere.
public struct ComparisonView: View {
    private enum Slot {
        case baseline
        case candidate
    }

    @State private var model = ComparisonViewModel()
    @State private var importing: Slot?
    @State private var exportDocument: TextExportDocument?
    @State private var exportType: UTType = .commaSeparatedText

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                slotPickers
                if let failure = model.loadFailure {
                    Text(failure).foregroundStyle(.red)
                }
                if let comparison = model.comparison {
                    if comparison.isComparable {
                        deltaTable(comparison)
                    } else {
                        mismatchBanner(comparison)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Pick Two Reports", systemImage: "square.split.2x1")
                    } description: {
                        Text("Comparisons need a baseline and a candidate report.")
                    }
                }
            }
            .padding(20)
        }
        .navigationSubtitle("Compare runs")
        .toolbar {
            Button("Export CSV", systemImage: "tablecells") { export(.commaSeparatedText) }
                .disabled(model.comparison == nil)
            Button("Export JSON", systemImage: "curlybraces") { export(.json) }
                .disabled(model.comparison == nil)
        }
        .fileImporter(
            isPresented: Binding(
                get: { importing != nil },
                set: { if !$0 { importing = nil } }),
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result, let slot = importing {
                model.load(url: url, asBaseline: slot == .baseline)
            }
            importing = nil
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "loupe-comparison"
        ) { _ in
            exportDocument = nil
        }
    }

    private var slotPickers: some View {
        HStack(spacing: 12) {
            slotButton(
                title: model.baseline?.name ?? "Choose Baseline…",
                symbol: "a.square", filled: model.baseline != nil
            ) { importing = .baseline }
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            slotButton(
                title: model.candidate?.name ?? "Choose Candidate…",
                symbol: "b.square", filled: model.candidate != nil
            ) { importing = .candidate }
            Spacer()
        }
    }

    private func slotButton(
        title: String, symbol: String, filled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(filled ? .accentColor : .secondary)
    }

    private func mismatchBanner(_ comparison: RunComparison) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("These runs are not comparable — no deltas will be shown.")
                        .bold()
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                Text("Every differing dimension must match before numbers mean anything:")
                    .foregroundStyle(.secondary)
                ForEach(comparison.mismatches) { mismatch in
                    HStack(spacing: 8) {
                        Text(mismatch.name)
                            .monospaced()
                            .frame(width: 130, alignment: .leading)
                        Text(mismatch.baseline).foregroundStyle(.orange)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(mismatch.candidate).foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .backgroundStyle(.red.opacity(0.08))
    }

    private func deltaTable(_ comparison: RunComparison) -> some View {
        GroupBox {
            Table(comparison.deltas ?? []) {
                TableColumn("Context") { delta in
                    Text("\(delta.contextTokens)").monospacedDigit()
                }
                .width(80)
                TableColumn("Metric") { delta in
                    Text(delta.metric)
                }
                .width(120)
                TableColumn("Baseline") { delta in
                    Text(String(format: "%.1f", delta.baselineP50)).monospacedDigit()
                }
                .width(100)
                TableColumn("Candidate") { delta in
                    Text(String(format: "%.1f", delta.candidateP50)).monospacedDigit()
                }
                .width(100)
                TableColumn("Δ") { delta in
                    Text(String(format: "%+.1f%%", delta.deltaPercent))
                        .monospacedDigit()
                        .foregroundStyle(abs(delta.deltaPercent) < 1 ? .secondary : .primary)
                        .bold(abs(delta.deltaPercent) >= 5)
                }
            }
            .frame(minHeight: 200)
        } label: {
            Label("Side by Side — p50", systemImage: "square.split.2x1")
        }
    }

    private func export(_ type: UTType) {
        exportType = type
        if type == .json {
            exportDocument = model.exportJSON().map { TextExportDocument(data: $0) }
        } else {
            exportDocument = model.exportCSV().map { TextExportDocument(data: Data($0.utf8)) }
        }
    }
}

/// Minimal FileDocument for fileExporter: the bytes are prebuilt.
struct TextExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
