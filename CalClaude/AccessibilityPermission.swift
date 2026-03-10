import ApplicationServices
import AppKit
import Foundation
import SwiftUI

enum AccessibilityPermission {
    /// Returns whether the app is trusted for Accessibility (required for global hotkeys).
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt asking the user to grant Accessibility permission, then returns current trust status.
    /// The system dialog has "Open System Settings" and "Deny". Does not open the pane automatically.
    static func requestWithPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings to Privacy & Security → Accessibility so the user can add or enable the app.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Observable trust state so the panel can show the permission view or the input view.
@MainActor
final class AccessibilityState: ObservableObject {
    @Published private(set) var isTrusted: Bool

    init() {
        // #region agent log
        DebugLog.log(location: "AccessibilityState:init", message: "reading isTrusted", hypothesisId: "H3")
        // #endregion
        self.isTrusted = AccessibilityPermission.isTrusted
    }

    func refresh() {
        // #region agent log
        DebugLog.log(location: "AccessibilityState:refresh", message: "refresh start", hypothesisId: "H2")
        // #endregion
        isTrusted = AccessibilityPermission.isTrusted
        // #region agent log
        DebugLog.log(location: "AccessibilityState:refresh", message: "refresh end", hypothesisId: "H2", data: ["isTrusted": isTrusted])
        // #endregion
    }
}
