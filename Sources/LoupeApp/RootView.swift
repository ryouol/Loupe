import LoupeCore
import SwiftUI

/// Root view: replays a fixture when `LOUPE_REPLAY_FIXTURE` names one
/// (that's `make replay`), otherwise shows the placeholder shell until the
/// real results view lands in M1.5.
public struct RootView: View {
    private let replayBasePath: String?

    public init(
        replayBasePath: String? = ProcessInfo.processInfo.environment["LOUPE_REPLAY_FIXTURE"]
    ) {
        self.replayBasePath = replayBasePath
    }

    public var body: some View {
        if let replayBasePath {
            ReplayView(basePath: replayBasePath)
        } else {
            VStack(spacing: 8) {
                Text("Loupe").font(.largeTitle).bold()
                Text("v\(Loupe.version)").foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}
