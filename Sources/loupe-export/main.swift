import Darwin
import Foundation
import LoupeApp

// Uses the same replay parser, metrics, source verification, and exporters as the app.
@main
struct EvidenceExport {
    @MainActor
    static func main() async {
        do { try await export() } catch {
            FileHandle.standardError.write(
                Data(("Export failed: \(error.localizedDescription)\n").utf8))
            exit(2)
        }
    }

    @MainActor
    static func export() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw NSError(
                domain: "LoupeExport", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: loupe-export <session-base-path> <output-base-path>"
                ])
        }
        let replay = ReplayViewModel(basePath: arguments[1])
        await replay.load()
        guard replay.isLoaded else {
            throw NSError(
                domain: "LoupeExport", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: replay.loadFailure ?? "Session failed to load"
                ])
        }
        let json = try replay.evidenceJSON()
        let csv = try replay.evidenceCSV()
        try json.write(to: URL(fileURLWithPath: arguments[2] + ".json"), options: .atomic)
        try csv.write(toFile: arguments[2] + ".csv", atomically: true, encoding: .utf8)
        print(
            "Replayed \(replay.totalEventCount) events, \(replay.samples.count) samples; "
                + "parser drops: \(replay.eventDrops) events, \(replay.sampleDrops) samples.")
    }
}
