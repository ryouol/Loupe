import XCTest

@testable import LoupeCore

/// Pins the committed LaunchDaemon plist to the constants SMAppService
/// matches against — the exact "plist filename must equal Label" mismatch
/// CLAUDE.md warns about, caught at test time instead of on real hardware.
final class DaemonContractTests: XCTestCase {
    private static let plistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Support")
        .appendingPathComponent(LoupeDaemon.plistName)

    func testLaunchDaemonPlistMatchesConstants() throws {
        let data = try Data(contentsOf: Self.plistURL)
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

        XCTAssertEqual(plist?["Label"] as? String, LoupeDaemon.machServiceName)
        XCTAssertEqual(plist?["BundleProgram"] as? String, "Contents/MacOS/loupedaemon")
        let machServices = plist?["MachServices"] as? [String: Any]
        XCTAssertNotNil(
            machServices?[LoupeDaemon.machServiceName],
            "daemon must expose its mach service under the shared name")
    }

    func testPlistNameDerivesFromServiceName() {
        XCTAssertEqual(LoupeDaemon.plistName, LoupeDaemon.machServiceName + ".plist")
    }
}

final class SessionFilePairTests: XCTestCase {
    func testEitherFileOfThePairIdentifiesTheSession() {
        let fromEvents = SessionFilePair(anyFileURL: URL(fileURLWithPath: "/tmp/run.ndjson"))
        let fromSystem = SessionFilePair(
            anyFileURL: URL(fileURLWithPath: "/tmp/run.system.ndjson"))
        XCTAssertEqual(fromEvents, fromSystem)
        XCTAssertEqual(fromEvents.basePath, "/tmp/run")
    }

    func testBareBasePathPassesThrough() {
        let pair = SessionFilePair(anyFileURL: URL(fileURLWithPath: "/tmp/run"))
        XCTAssertEqual(pair.basePath, "/tmp/run")
        XCTAssertEqual(pair.eventsURL.path, "/tmp/run.ndjson")
        XCTAssertEqual(pair.systemURL.path, "/tmp/run.system.ndjson")
        XCTAssertEqual(pair.name, "run")
    }
}
