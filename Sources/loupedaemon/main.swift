import Foundation
import LoupeCore
import LoupeTelemetry
import ServiceManagement

// Thin by design: the root helper exposes telemetry only. Adapter input and
// session persistence stay in the logged-in user's app process, so malformed
// runtime data never crosses a privilege boundary.
func logLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Maintenance flags for headless management. Invoked from inside the app
// bundle this binary's Bundle.main is Loupe.app, so SMAppService resolves
// the same plist the GUI's Install button uses.
if let command = CommandLine.arguments.dropFirst().first {
    let service = SMAppService.daemon(plistName: LoupeDaemon.plistName)
    switch command {
    case "--status":
        logLine("daemon status: \(service.status.rawValue) (\(describe(service.status)))")
        exit(0)
    case "--register":
        do {
            try service.register()
            logLine("registered; status now \(describe(service.status))")
            exit(0)
        } catch {
            logLine("register failed: \(error)")
            exit(1)
        }
    case "--unregister":
        do {
            try service.unregister()
            logLine("unregistered; status now \(describe(service.status))")
            exit(0)
        } catch {
            logLine("unregister failed: \(error)")
            exit(1)
        }
    default:
        logLine("usage: loupedaemon [--status | --register | --unregister]")
        exit(2)
    }
}

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

let delegate = DaemonListenerDelegate(
    daemonVersion: Loupe.version,
    peerValidator: .production(appBundleIdentifier: LoupeDaemon.appBundleIdentifier)
) { cadence in
    LiveTelemetrySource(
        targetPID: nil, cadence: cadence,
        makePowerReader: { IOReportPowerReader() })
}
let listener = NSXPCListener(machServiceName: LoupeDaemon.machServiceName)
listener.delegate = delegate
listener.resume()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSources = [SIGTERM, SIGINT].map { signalNumber in
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        logLine("loupedaemon stopping")
        exit(0)
    }
    source.resume()
    return source
}

logLine("loupedaemon \(Loupe.version) listening on \(LoupeDaemon.machServiceName)")
withExtendedLifetime(terminationSources) {
    RunLoop.main.run()
}
