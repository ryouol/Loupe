import Foundation
import LoupeCore

public enum SampleSession {
    public static func basePath(in bundle: Bundle = .main) -> String? {
        var eventURL =
            bundle.url(
                forResource: "demo-session", withExtension: "ndjson", subdirectory: "Samples")
            ?? bundle.url(forResource: "demo-session", withExtension: "ndjson")
        #if DEBUG
            if eventURL == nil {
                eventURL = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/Samples/demo-session.ndjson")
            }
        #endif
        guard let eventURL else { return nil }
        let pair = SessionFilePair(anyFileURL: eventURL)
        guard FileManager.default.isReadableFile(atPath: pair.systemURL.path) else { return nil }
        return pair.basePath
    }
}
