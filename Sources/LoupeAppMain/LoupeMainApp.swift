import LoupeApp
import SwiftUI

/// App entry point. Minimal by design — it only wires up `LoupeApp`.
@main
struct LoupeMainApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
