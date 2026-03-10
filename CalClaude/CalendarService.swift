import EventKit
import Foundation

final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    private init() {}

    /// Request calendar access. Call before creating events.
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Creates a calendar event from a validated payload. Returns error message on failure.
    func createEvent(from payload: CalendarEventPayload) -> Result<Void, String> {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        guard let dateOnly = dateFormatter.date(from: payload.date) else {
            return .failure("Invalid date: \(payload.date). Use YYYY-MM-DD.")
        }
        guard let timeOnly = timeFormatter.date(from: payload.time) else {
            return .failure("Invalid time: \(payload.time). Use HH:mm.")
        }
        let calendar = Calendar.current
        guard let startDate = calendar.date(
            bySettingHour: calendar.component(.hour, from: timeOnly),
            minute: calendar.component(.minute, from: timeOnly),
            second: 0,
            of: dateOnly
        ) else {
            return .failure("Could not combine date and time.")
        }
        guard let endDate = calendar.date(byAdding: .minute, value: payload.duration, to: startDate) else {
            return .failure("Invalid duration.")
        }

        let ekCalendar: EKCalendar
        if let cal = store.calendar(withIdentifier: payload.calendar) {
            ekCalendar = cal
        } else {
            let byName = store.calendars(for: .event).filter {
                $0.title == payload.calendar && $0.allowsContentModifications
            }
            if let cal = byName.first {
                ekCalendar = cal
            } else if let defaultCal = store.defaultCalendarForNewEvents {
                ekCalendar = defaultCal
            } else {
                return .failure("No writable calendar found. Open Calendar.app and create a calendar first, then try again.")
            }
        }

        guard ekCalendar.allowsContentModifications else {
            return .failure("Calendar \"\(ekCalendar.title)\" is not writable.")
        }

        let event = EKEvent(eventStore: store)
        event.title = payload.title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = ekCalendar

        do {
            try store.save(event, span: .thisEvent)
            return .success(())
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
