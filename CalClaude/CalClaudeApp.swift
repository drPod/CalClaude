import SwiftUI

@main
struct CalClaudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("CalClaude", systemImage: "calendar") {
            Button("Show Panel") {
                appDelegate.showPanel()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Divider()

            Button("Settings…") {
                appDelegate.showSettings()
            }

            Button("Open Accessibility Settings") {
                AccessibilityPermission.openAccessibilitySettings()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
