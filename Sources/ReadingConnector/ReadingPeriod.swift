import Foundation

/// "since" / "period" values the tools and CLI accept: `today`, `30m`, `24h`, `7d`, `2w`, or a
/// date (`2027-01-08` or full ISO 8601).
public enum ReadingPeriod {
    public static let help = "today, 24h, 7d, 30d, 2w, or a date like 2027-01-08"

    /// The start of the window ending `now`, or nil when `text` is not a period.
    public static func start(_ text: String, now: Date, timeZone: TimeZone = .current) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if value == "today" { return calendar.startOfDay(for: now) }
        if let unit = value.last, let amount = Double(value.dropLast()), amount >= 0 {
            let seconds: Double? = switch unit {
            case "m": 60
            case "h": 3_600
            case "d": 86_400
            case "w": 7 * 86_400
            default: nil
            }
            if let seconds { return now.addingTimeInterval(-amount * seconds) }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3 {
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        return nil
    }
}
