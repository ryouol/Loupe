import Foundation
import LoupeCore
import LoupeSampler

// Thin by design: all real logic lives in LoupeSampler where it is testable
// in-process. This binary only binds the mach service and runs the loop.
// launchd starts us on demand when a client connects to the service name.
let delegate = DaemonListenerDelegate(daemonVersion: Loupe.version)
let listener = NSXPCListener(machServiceName: LoupeDaemon.machServiceName)
listener.delegate = delegate
listener.resume()

FileHandle.standardError.write(
    Data("loupedaemon \(Loupe.version) listening on \(LoupeDaemon.machServiceName)\n".utf8))
RunLoop.main.run()
