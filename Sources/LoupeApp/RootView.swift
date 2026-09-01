import LoupeCore
import LoupeStore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    public static let loupeOpenSession = Notification.Name("ai.squint.loupe.openSession")
}

public struct RootView: View {
    enum Screen: String, CaseIterable, Identifiable {
        case overview
        case record
        case history
        case session
        case results
        case compare
        case daemon
        case about

        var id: String { rawValue }

        var label: String {
            switch self {
            case .overview: return "Overview"
            case .record: return "Record"
            case .history: return "History"
            case .session: return "Analysis"
            case .results: return "Results"
            case .compare: return "Compare"
            case .daemon: return "Telemetry"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.50percent"
            case .record: return "record.circle"
            case .history: return "clock.arrow.circlepath"
            case .session: return "waveform.path.ecg.rectangle"
            case .results: return "chart.bar.xaxis"
            case .compare: return "square.split.2x1"
            case .daemon: return "bolt.shield"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Screen?
    @State private var sessionBasePath: String?
    @State private var isImporting = false
    @State private var sampleError: String?
    @State private var daemonModel: DaemonViewModel
    @State private var recordingModel: RecordingViewModel

    public init(
        replayBasePath: String? = ProcessInfo.processInfo
            .environment[LoupeEnvironment.replaySessionVariable],
        daemonClient: any DaemonServiceClient = SMAppServiceDaemonClient(),
        recordingModel: RecordingViewModel? = nil
    ) {
        _selection = State(initialValue: replayBasePath == nil ? .overview : .session)
        _sessionBasePath = State(initialValue: replayBasePath)
        _daemonModel = State(initialValue: DaemonViewModel(client: daemonClient))
        _recordingModel = State(initialValue: recordingModel ?? .live())
    }

    public var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $selection) { screen in
                Label(screen.label, systemImage: screen.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch selection ?? .overview {
            case .overview:
                OverviewView(
                    daemonModel: daemonModel,
                    onStartRecording: { selection = .record },
                    onOpenSample: openSample,
                    onOpenSession: { isImporting = true },
                    onShowDaemon: { selection = .daemon })
            case .record:
                RecordingView(model: recordingModel)
            case .history:
                SessionHistoryView(
                    model: recordingModel,
                    onOpen: { summary in openSession(basePath: summary.basePath) },
                    onOpenSample: openSample)
            case .session:
                SessionScreen(
                    basePath: $sessionBasePath,
                    onOpen: { isImporting = true },
                    onOpenSample: openSample)
            case .results:
                ResultsView()
            case .compare:
                ComparisonView()
            case .daemon:
                DaemonView(model: daemonModel)
            case .about:
                AboutView()
            }
        }
        .navigationTitle("Loupe")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "ndjson") ?? .data]
        ) { result in
            if case .success(let url) = result {
                openSession(at: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loupeOpenSession)) { _ in
            isImporting = true
        }
        .alert(
            "Sample session unavailable",
            isPresented: Binding(
                get: { sampleError != nil },
                set: { if !$0 { sampleError = nil } })
        ) {
            Button("OK", role: .cancel) { sampleError = nil }
        } message: {
            Text(sampleError ?? "The bundled fixture could not be read.")
        }
    }

    private func openSession(at url: URL) {
        openSession(basePath: SessionFilePair(anyFileURL: url).basePath)
    }

    private func openSession(basePath: String) {
        sessionBasePath = basePath
        selection = .session
    }

    private func openSample() {
        guard let basePath = SampleSession.basePath() else {
            sampleError = "The app bundle does not contain a complete sanitized sample pair."
            return
        }
        openSession(basePath: basePath)
    }
}
