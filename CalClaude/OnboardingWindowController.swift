import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let state = OnboardingState()

    /// Shows onboarding if any requirement is unmet, regardless of the
    /// "completed" flag. The flag only suppresses the wizard when everything
    /// is still satisfied.
    func showIfNeeded(then completion: @escaping () -> Void) {
        state.refreshAll()
        if state.allRequirementsMet {
            if !state.isCompleted { state.markCompleted() }
            completion()
            return
        }
        showWindow(then: completion)
    }

    private func showWindow(then completion: @escaping () -> Void) {
        let onComplete = { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.state.markCompleted()
            completion()
        }

        let hostingView = NSHostingView(
            rootView: OnboardingView(state: state, onComplete: onComplete)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to CalClaude"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
