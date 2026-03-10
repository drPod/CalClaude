import Foundation

// MARK: - String + Error conformance for Result<..., String> usage

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

/// Validated calendar event payload from Claude; schema: title, date (YYYY-MM-DD), time (HH:mm), duration (minutes), calendar.
struct CalendarEventPayload: Codable {
    let title: String
    let date: String
    let time: String
    let duration: Int
    let calendar: String
}

enum CalendarEventPayloadValidation {
    private static let datePattern = #"^\d{4}-\d{2}-\d{2}$"#
    private static let timePattern = #"^\d{1,2}:\d{2}$"#

    /// Validates and decodes JSON into CalendarEventPayload.
    static func validate(_ jsonData: Data) -> Result<CalendarEventPayload, String> {
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode(RawPayload.self, from: jsonData) else {
            return .failure("Invalid JSON or missing required fields.")
        }
        if let msg = validateFields(raw) {
            return .failure(msg)
        }
        guard let payload = raw.toPayload() else {
            return .failure("Invalid date, time, or duration.")
        }
        return .success(payload)
    }

    /// Validates a decoded struct with optional types; returns error string or nil.
    private static func validateFields(_ raw: RawPayload) -> String? {
        if raw.title == nil || raw.title?.isEmpty == true { return "Missing or empty title." }
        if raw.date == nil || raw.date?.isEmpty == true { return "Missing or empty date." }
        if raw.time == nil || raw.time?.isEmpty == true { return "Missing or empty time." }
        if raw.duration == nil { return "Missing duration." }
        if let d = raw.duration, d <= 0 { return "Duration must be greater than 0." }
        if raw.calendar == nil || raw.calendar?.isEmpty == true { return "Missing or empty calendar." }

        let dateRegex = try? NSRegularExpression(pattern: datePattern)
        let timeRegex = try? NSRegularExpression(pattern: timePattern)
        let dateStr = raw.date ?? ""
        let timeStr = raw.time ?? ""
        let dateRange = NSRange(dateStr.startIndex..<dateStr.endIndex, in: dateStr)
        let timeRange = NSRange(timeStr.startIndex..<timeStr.endIndex, in: timeStr)
        if dateRegex?.firstMatch(in: dateStr, range: dateRange) == nil {
            return "Date must be YYYY-MM-DD."
        }
        if timeRegex?.firstMatch(in: timeStr, range: timeRange) == nil {
            return "Time must be HH:mm or H:mm."
        }
        return nil
    }

    private struct RawPayload: Codable {
        let title: String?
        let date: String?
        let time: String?
        let duration: Int?
        let calendar: String?

        func toPayload() -> CalendarEventPayload? {
            guard let title = title, !title.isEmpty,
                  let date = date, !date.isEmpty,
                  let time = time, !time.isEmpty,
                  let duration = duration, duration > 0,
                  let calendar = calendar, !calendar.isEmpty else { return nil }
            return CalendarEventPayload(
                title: title,
                date: date,
                time: time,
                duration: duration,
                calendar: calendar
            )
        }
    }
}
