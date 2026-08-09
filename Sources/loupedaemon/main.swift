import Foundation
import LoupeCore
import LoupeSampler

// Thin by design: logic lives in LoupeSampler where it is testable. launchd
// starts this on demand when a client connects to the mach service. The
// telemetry choice lives here, at the composition root — M1.x swaps in the
// privileged IOReport source without touching the XPC plumbing.
let delegate = DaemonListenerDelegate(daemonVersion: Loupe.version) { cadence in
    LiveTelemetrySource(targetPID: nil, cadence: cadence)
}
let listener = NSXPCListener(machServiceName: LoupeDaemon.machServiceName)
listener.delegate = delegate
listener.resume()

FileHandle.standardError.write(
    Data("loupedaemon \(Loupe.version) listening on \(LoupeDaemon.machServiceName)\n".utf8))
RunLoop.main.run()
