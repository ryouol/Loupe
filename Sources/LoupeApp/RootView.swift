import LoupeCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    public static let loupeOpenSession = Notification.Name("ai.squint.loupe.openSession")
}

public struct RootView: View {
    enum Screen: String, CaseIterable, Identifiable {
        case overview
        case session
        case daemon

        var id: String { rawValue }

        var label: String {
            switch self {
            case .overview: return "Overview"
            case .session: return "Session"
            case .daemon: return "Daemon"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.50percent"
            case .session: return "waveform.path.ecg.rectangle"
            case .daemon: return "bolt.shield"
            }
        }
    }

    @State private var selection: Screen?
    @State private var sessionBasePath: String?
    @State private var isImporting = false
    @State private var daemonModel: DaemonViewModel

    public init(
        replayBasePath: String? = ProcessInfo.processInfo
            .environment[LoupeEnvironment.replaySessionVariable],
        daemonClient: any DaemonServiceClient = SMAppServiceDaemonClient()
    ) {
        _selection = State(initialValue: replayBasePath == nil ? .overview : .session)
        _sessionBasePath = State(initialValue: replayBasePath)
        _daemonModel = State(initialValue: DaemonViewModel(client: daemonClient))
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
                    sessionName: sessionBasePath.map { URL(fileURLWithPath: $0).lastPathComponent },
                    onOpenSession: { isImporting = true },
                    onShowDaemon: { selection = .daemon })
            case .session:
                SessionScreen(basePath: $sessionBasePath, onOpen: { isImporting = true })
            case .daemon:
                DaemonView(model: daemonModel)
            }
        }
        .navigationTitle("Loupe")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "ndjson") ?? .data, .json]
        ) { result in
            if case .success(let url) = result {
                openSession(at: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loupeOpenSession)) { _ in
            isImporting = true
        }
    }

    private func openSession(at url: URL) {
        sessionBasePath = SessionFilePair(anyFileURL: url).basePath
        selection = .session
    }
}
