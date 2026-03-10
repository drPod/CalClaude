import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            stepContent
            Spacer()
            progressDots
        }
        .padding(32)
        .frame(width: 520, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch state.currentStep {
        case .cliCheck:
            cliCheckStep
        case .accessibility:
            accessibilityStep
        case .calendar:
            calendarStep
        }
    }

    // MARK: - Step 1: CLI Check

    private var cliCheckStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.purple)

            stepLabel(1)

            Text("Install Claude CLI")
                .font(.title2.bold())

            if let healthError = state.cliHealthError {
                healthWarning(healthError)
            } else if !state.cliFound {
                Text("CalClaude needs the Claude CLI to communicate with Claude. Install it first, then click Check Again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Claude CLI is installed and healthy.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                if !state.cliFound {
                    Button("Install Guide") {
                        NSWorkspace.shared.open(CLICheck.installURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                Button("Check Again") {
                    state.refreshAll()
                    advanceIfMet()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func healthWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step 2: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(.purple)

            stepLabel(2)

            Text("Grant Accessibility Access")
                .font(.title2.bold())

            Text("The global shortcut (⌘⌥P) requires Accessibility permission. Add CalClaude in System Settings, then come back — this screen will advance automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Open System Settings") {
                _ = AccessibilityPermission.requestWithPrompt()
                AccessibilityPermission.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if AXIsProcessTrusted() {
                state.refreshAll()
                advanceIfMet()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check as soon as user returns from System Settings
            if AXIsProcessTrusted() {
                state.refreshAll()
                advanceIfMet()
            }
        }
    }

    // MARK: - Step 3: Calendar

    private var calendarStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.purple)

            stepLabel(3)

            Text("Allow Calendar Access")
                .font(.title2.bold())

            Text("CalClaude needs calendar access to create events. Click Grant Access to allow it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Grant Access") {
                    Task {
                        let granted = await CalendarService.shared.requestAccess()
                        state.calendarGranted = granted
                        state.refreshAll()
                        advanceIfMet()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button("Check Again") {
                    state.refreshAll()
                    advanceIfMet()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private func stepLabel(_ number: Int) -> some View {
        Text("STEP \(number) OF 3")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= state.currentStep.rawValue ? Color.purple : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func advanceIfMet() {
        if state.allRequirementsMet {
            state.markCompleted()
            onComplete()
        }
    }
}
