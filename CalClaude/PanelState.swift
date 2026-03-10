import Foundation
import SwiftUI

@MainActor
final class PanelState: ObservableObject {
    @Published var isLoading = false
    @Published var validationError: String?
    @Published var pendingEvent: CalendarEventPayload?
    @Published var eventCreatedMessage: String?

    func clearErrorAndPending() {
        validationError = nil
        pendingEvent = nil
        eventCreatedMessage = nil
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    func setValidationError(_ message: String) {
        validationError = message
        pendingEvent = nil
    }

    func setPendingEvent(_ payload: CalendarEventPayload) {
        pendingEvent = payload
        validationError = nil
    }

    func setEventCreated(_ title: String) {
        eventCreatedMessage = "Created: \(title)"
        pendingEvent = nil
    }

    func clearCreatedMessage() {
        eventCreatedMessage = nil
    }
}
