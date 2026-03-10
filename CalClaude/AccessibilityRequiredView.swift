import SwiftUI

/// Root view for the floating panel: shows the permission screen or the input panel based on Accessibility trust.
struct PanelRootView: View {
    @ObservedObject var accessibilityState: AccessibilityState
    @ObservedObject var panelState: PanelState
    var onDismiss: () -> Void
    var onSubmit: (String, String?) -> Void
    var onConfirmCreate: (CalendarEventPayload) -> Void
    var onCancel: () -> Void

    var body: some View {
        // #region agent log
        let _ = { DebugLog.log(location: "PanelRootView:body", message: "body evaluated", hypothesisId: "H3", data: ["isTrusted": accessibilityState.isTrusted]) }()
        // #endregion
        if accessibilityState.isTrusted {
            InputPanelView(
                panelState: panelState,
                onDismiss: onDismiss,
                onSubmit: onSubmit,
                onConfirmCreate: onConfirmCreate,
                onCancel: onCancel
            )
        } else {
            AccessibilityRequiredView(onPermissionGranted: { accessibilityState.refresh() })
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

            Text("The global shortcut (⌘⇧C) works from any app, so macOS requires Accessibility permission. Grant access in System Settings to use the shortcut.")
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
