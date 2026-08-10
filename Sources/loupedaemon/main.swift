import Foundation
import LoupeCore
import LoupeSampler
import LoupeStore

// Thin by design: logic lives in LoupeSampler/LoupeStore where it is
// testable. launchd starts this on demand when a client connects to the mach
// service. Composition choices (which telemetry source, where sessions
// persist) live here and nowhere else.
func logLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let delegate = DaemonListenerDelegate(daemonVersion: Loupe.version) { cadence in
    LiveTelemetrySource(
        targetPID: nil, cadence: cadence,
        makePowerReader: { IOReportPowerReader() })
}
let listener = NSXPCListener(machServiceName: LoupeDaemon.machServiceName)
listener.delegate = delegate
listener.resume()

// Adapter ingest: Unix socket → validated envelopes → per-run SQLite. Bind
// failure degrades to XPC-only service; adapters see counted drops, the
// daemon never exits over it.
let ingest = Task {
    let server = EventSocketServer(socketPath: LoupeDaemon.adapterSocketPath)
    do {
        let stream = try await server.start()
        let sessions = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Loupe/sessions", isDirectory: true)
        let router = SessionEventRouter(directory: sessions, host: HostInfo.fingerprint())
        logLine("adapter socket listening at \(LoupeDaemon.adapterSocketPath)")
        for await envelope in stream {
            do {
                try await router.route(envelope)
            } catch {
                logLine("persist failed for \(envelope.runId): \(error)")
            }
        }
        try await router.flushAll()
    } catch {
        logLine("adapter socket unavailable (\(error)) — running XPC-only")
    }
}

logLine("loupedaemon \(Loupe.version) listening on \(LoupeDaemon.machServiceName)")
withExtendedLifetime(ingest) {
    RunLoop.main.run()
}
