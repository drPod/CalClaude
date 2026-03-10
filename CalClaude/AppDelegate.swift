import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var hotKeyManager: HotKeyManager?
    private let accessibilityState = AccessibilityState()
    let panelState = PanelState()
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onboardingController = OnboardingWindowController()
        onboardingController?.showIfNeeded { [weak self] in
            self?.proceedWithSetup()
        }
    }

    private func proceedWithSetup() {
        createFloatingPanel()
        registerHotkey()
        observeAccessibilityChanges()
    }

    private func createFloatingPanel() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 140),
            backing: .buffered,
            defer: false
        )
        panel.title = "CalClaude"
        panel.contentView = NSHostingView(
            rootView: PanelRootView(
                accessibilityState: accessibilityState,
                panelState: panelState,
                onDismiss: { [weak self] in self?.hidePanel() },
                onSubmit: { [weak self] text, screenshotPath in
                    self?.submitToClaude(prompt: text, screenshotPath: screenshotPath)
                },
                onConfirmCreate: { [weak self] payload in
                    self?.createEvent(payload: payload)
                },
                onCancel: { [weak self] in
                    ClaudeCLIService.shared.cancel()
                    self?.panelState.setLoading(false)
                }
            )
        )
        floatingPanel = panel
    }

    private func observeAccessibilityChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.accessibilityState.refresh()
            }
        }
    }

    private func registerHotkey() {
        let keyCode = UInt32(kVK_ANSI_C)
        let modifiers = CarbonModifiers.from(cocoa: [.command, .shift])
        hotKeyManager = HotKeyManager(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            self?.showPanel()
        }
    }

    func showPanel() {
        guard let panel = floatingPanel else { return }
        panel.center()
        panel.orderFront(nil)
        panel.makeKey()
    }

    func hidePanel() {
        panelState.clearErrorAndPending()
        floatingPanel?.orderOut(nil)
    }

    func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "CalClaude Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func submitToClaude(prompt: String, screenshotPath: String?) {
        panelState.clearErrorAndPending()
        panelState.setLoading(true)
        Task { @MainActor in
            let result = await ClaudeCLIService.shared.runClaude(prompt: prompt, screenshotPath: screenshotPath)
            panelState.setLoading(false)
            switch result {
            case .success(let data):
                switch CalendarEventPayloadValidation.validate(data) {
                case .success(let payload):
                    panelState.setPendingEvent(payload)
                case .failure(let message):
                    panelState.setValidationError(message)
                }
            case .failure(let message):
                panelState.setValidationError(message)
            }
        }
    }

    private func createEvent(payload: CalendarEventPayload) {
        Task { @MainActor in
            let granted = await CalendarService.shared.requestAccess()
            guard granted else {
                panelState.setValidationError("Calendar access denied. Grant access in System Settings → Privacy & Security → Calendars.")
                return
            }
            switch CalendarService.shared.createEvent(from: payload) {
            case .success:
                panelState.setEventCreated(payload.title)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.panelState.clearCreatedMessage()
                    self?.hidePanel()
                }
            case .failure(let message):
                panelState.setValidationError(message)
            }
        }
    }
}
