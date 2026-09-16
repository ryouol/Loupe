import Darwin
import Foundation
import LoupeSampler
import LoupeStore

// Headless access to the app's recorder for repeatable runtime integration checks.
@main
struct Capture {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw NSError(
                    domain: "LoupeCapture", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "usage: loupe-capture <storage-root>; newline or EOF stops recording"
                    ])
            }
            let paths = LoupeStoragePaths(
                applicationSupportDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
            let recorder = SessionRecorder(paths: paths, host: HostInfo.fingerprint())
            let session = try await recorder.start(displayName: "CLI capture")
            let ready = try JSONSerialization.data(
                withJSONObject: [
                    "socket": paths.adapterSocketURL.path,
                    "runID": session.runID,
                    "basePath": session.basePath,
                ], options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: ready + Data([10]))
            _ = await Task.detached { readLine() }.value
            let stopped = try await recorder.stop()
            FileHandle.standardError.write(
                Data(
                    ("Recorded \(stopped.eventCount) events and \(stopped.sampleCount) samples.\n")
                        .utf8))
        } catch {
            FileHandle.standardError.write(
                Data(("Capture failed: \(error.localizedDescription)\n").utf8))
            exit(2)
        }
    }
}
