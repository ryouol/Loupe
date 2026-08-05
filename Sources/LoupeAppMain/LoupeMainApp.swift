import LoupeApp
import SwiftUI

@main
struct LoupeMainApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1_040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Session…") {
                    NotificationCenter.default.post(name: .loupeOpenSession, object: nil)
                }
                .keyboardShortcut("o")
            }
        }
    }
}
