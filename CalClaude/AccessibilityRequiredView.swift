import SwiftUI

/// Root view for the floating panel: shows the permission screen or the input panel based on Accessibility trust.
struct PanelRootView: View {
    @ObservedObject var accessibilityState: AccessibilityState
    @ObservedObject var screenRecordingState: ScreenRecordingState
    @ObservedObject var screenCaptureService: ScreenCaptureService
    @ObservedObject var panelState: PanelState
    var onDismiss: () -> Void
    var onSubmit: (String, String?) -> Void
    var onConfirmCreate: (CalendarEventPayload) -> Void
    var onCancel: () -> Void

    var body: some View {
        // #region agent log
        let _ = { DebugLog.log(location: "PanelRootView:body", message: "body evaluated", hypothesisId: "H3", data: ["isTrusted": accessibilityState.isTrusted]) }()
        // #endregion
        if !accessibilityState.isTrusted {
            AccessibilityRequiredView(onPermissionGranted: { accessibilityState.refresh() })
        } else if !screenRecordingState.isAuthorized {
            ScreenRecordingRequiredView(onPermissionGranted: { screenRecordingState.refresh() })
        } else {
            InputPanelView(
                panelState: panelState,
                screenCaptureService: screenCaptureService,
                onDismiss: onDismiss,
                onSubmit: onSubmit,
                onConfirmCreate: onConfirmCreate,
                onCancel: onCancel
            )
        }
    }
}

struct AccessibilityRequiredView: View {
    var onPermissionGranted: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Accessibility permission needed")
                .font(.headline)

            Text("The global shortcut (⌘⌥P) works from any app, so macOS requires Accessibility permission. Grant access in System Settings to use the shortcut.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    AccessibilityPermission.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)

                Button("Check Again") {
                    onPermissionGranted()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 100)
        .background(.ultraThinMaterial)
    }
}

struct ScreenRecordingRequiredView: View {
    var onPermissionGranted: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Screen Recording permission needed")
                .font(.headline)

            Text("CalClaude captures the frontmost window so Claude can parse events from what you see on screen. Grant Screen Recording access in System Settings. You may need to restart the app after granting permission.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    ScreenRecordingPermission.openSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("Check Again") {
                    onPermissionGranted()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 100)
        .background(.ultraThinMaterial)
    }
}
