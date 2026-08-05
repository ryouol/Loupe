import LoupeCore
import SwiftUI

/// Root view of the app — a placeholder until the results and timeline views
/// arrive (M1.5, M2.2).
public struct RootView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Text("Loupe").font(.largeTitle).bold()
            Text("v\(Loupe.version)").foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
