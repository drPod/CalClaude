import EventKit
import Foundation
import SwiftUI

@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable { case cliCheck, accessibility, calendar }

    @Published var currentStep: Step = .cliCheck
    @Published var cliFound = false
    @Published var cliHealthError: String?
    @Published var accessibilityGranted = false
    @Published var calendarGranted = false

    static let completedKey = "calclaude.onboardingCompleted"

    var isCompleted: Bool { UserDefaults.standard.bool(forKey: Self.completedKey) }

    func markCompleted() { UserDefaults.standard.set(true, forKey: Self.completedKey) }

    /// Checks all 3 requirements and advances currentStep to the first unmet one.
    func refreshAll() {
        cliFound = CLICheck.isAvailable
        cliHealthError = cliFound ? CLICheck.healthCheck : nil
        accessibilityGranted = AXIsProcessTrusted()
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            calendarGranted = calendarStatus == .fullAccess || calendarStatus == .authorized
        } else {
            calendarGranted = calendarStatus == .authorized
        }
        currentStep = firstUnmetStep ?? .calendar
    }

    var allRequirementsMet: Bool {
        cliFound && cliHealthError == nil && accessibilityGranted && calendarGranted
    }

    private var firstUnmetStep: Step? {
        if !cliFound || cliHealthError != nil { return .cliCheck }
        if !accessibilityGranted { return .accessibility }
        if !calendarGranted { return .calendar }
        return nil
    }
}
