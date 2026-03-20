import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenRecordingPermission {
    /// Quick synchronous check — may return stale `false` after user grants permission until app restart.
    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Async check that actually tests whether we can enumerate windows.
    /// This reflects the real permission state even without an app restart.
    static func checkAccess() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func requestAccess() {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class ScreenRecordingState: ObservableObject {
    @Published var isAuthorized: Bool

    init() {
        self.isAuthorized = ScreenRecordingPermission.isAuthorized
    }

    func refresh() {
        // Sync check first (fast path)
        if ScreenRecordingPermission.isAuthorized {
            isAuthorized = true
            return
        }
        // Fall back to async check that reflects real permission state
        Task { @MainActor in
            let authorized = await ScreenRecordingPermission.checkAccess()
            self.isAuthorized = authorized
        }
    }
}
