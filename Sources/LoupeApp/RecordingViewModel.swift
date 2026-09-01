import AppKit
import Foundation
import LoupeSampler
import LoupeStore
import Observation

@MainActor
@Observable
public final class RecordingViewModel {
    private let recorder: SessionRecorder?
    private let library: SessionLibrary?
    private let socketPathValue: String?
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public private(set) var current: SessionSummary?
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var isBusy = false
    public private(set) var lastError: String?
    public let setupFailure: String?

    public init(
        recorder: SessionRecorder?, library: SessionLibrary?,
        socketPath: String?, setupFailure: String? = nil
    ) {
        self.recorder = recorder
        self.library = library
        self.socketPathValue = socketPath
        self.setupFailure = setupFailure
    }

    public static func live() -> RecordingViewModel {
        do {
            let paths = try LoupeStoragePaths.userDefault()
            let recorder = SessionRecorder(paths: paths, host: HostInfo.fingerprint())
            return RecordingViewModel(
                recorder: recorder,
                library: SessionLibrary(paths: paths),
                socketPath: paths.adapterSocketURL.path)
        } catch {
            return RecordingViewModel(
                recorder: nil, library: nil, socketPath: nil,
                setupFailure: "Local storage is unavailable: \(error.localizedDescription)")
        }
    }

    public var isActive: Bool {
        guard let current else { return false }
        return !current.state.isTerminal
    }

    public var socketPath: String? { socketPathValue }
    public var runID: String? { current?.runID }

    public func observe() async {
        guard observationTask == nil, let recorder else { return }
        let updates = await recorder.updates()
        observationTask = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { break }
                self.current = update
            }
        }
        await refreshHistory()
    }

    public func start(displayName: String? = nil) async {
        guard let recorder, !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            current = try await recorder.start(displayName: displayName)
        } catch {
            lastError = "Recording could not start: \(error.localizedDescription)"
        }
    }

    public func stop() async {
        guard let recorder, isActive, !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            current = try await recorder.stop()
            await refreshHistory()
        } catch {
            lastError = "Recording could not stop cleanly: \(error.localizedDescription)"
        }
    }

    public func refreshHistory() async {
        guard let library else { return }
        do {
            let loaded = try await library.sessions()
            // The manifest is durable while a recording is live. The library
            // conservatively labels any nonterminal manifest as interrupted
            // for cold-start recovery, but this process knows when it still
            // owns that session and must keep the live state visible.
            sessions = loaded.map { session in
                guard let current, current.storageID == session.storageID, isActive else {
                    return session
                }
                return current
            }
        } catch {
            lastError = "Session history is unavailable: \(error.localizedDescription)"
        }
    }

    public func delete(_ session: SessionSummary) async {
        guard let library, !isBusy else { return }
        guard !(isActive && current?.storageID == session.storageID) else {
            lastError = "Stop the active recording before deleting it."
            return
        }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await library.delete(session)
            sessions.removeAll { $0.storageID == session.storageID }
            if current?.storageID == session.storageID, current?.state.isTerminal == true {
                current = nil
            }
        } catch {
            lastError = "Session could not be deleted: \(error.localizedDescription)"
        }
    }

    public func copyAdapterEnvironment() {
        guard let socketPath, let runID else { return }
        let command =
            "export LOUPE_SOCKET_PATH=\(shellQuote(socketPath))\n"
            + "export LOUPE_RUN_ID=\(shellQuote(runID))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
