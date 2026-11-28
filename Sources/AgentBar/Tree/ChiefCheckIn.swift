import Foundation

/// How often a chief's check-ins run (chief redesign item 14): multiplies the chief's base interval
/// on the dashboard (`dashboard/server/lib/chief_checkin.py` `PACES`). Raw values are the wire strings.
enum ChiefCheckInPace: String, CaseIterable, Sendable {
    case rush
    case steady
    case paceOut = "pace-out"
    case quiet

    var title: String {
        switch self {
        case .rush: "Rush"
        case .steady: "Steady"
        case .paceOut: "Pace out"
        case .quiet: "Quiet"
        }
    }

    /// What the pace does, in the menu.
    var detail: String {
        switch self {
        case .rush: "twice as often"
        case .steady: "the chief's own schedule"
        case .paceOut: "half as often"
        case .quiet: "no check-ins"
        }
    }
}

/// One chief's check-in timer state, as the dashboard owns it (`chief_timer.ChiefTimer.view`): the
/// last completed check-in, the next due time, overdue, and the pace / sleep-time settings.
struct ChiefCheckIn: Equatable, Sendable {
    enum State: String, Sendable {
        case ok, due, overdue, quiet, gone
        case noSchedule = "no-schedule"
        case error
    }

    /// `<project>/<chief name>` — what `POST /api/chief/settings` names.
    let chiefKey: String
    let state: State
    let lastCheckInAt: Date?
    /// A check-in that started and hasn't finished yet.
    let runningSince: Date?
    let nextDueAt: Date?
    let overdueSeconds: Int
    let pace: ChiefCheckInPace
    let sleepCheckins: Bool
    /// Plain English, already reflecting pace + sleep-time ("every 2h, 08:07-19:59, Mon-Sat").
    let schedule: String
    /// False: the dashboard only tracks + shows; the chief's own schedule wakes it.
    let wakeEnabled: Bool
    /// The last wake the dashboard sent: "delivered" / "failed" / "deferred" / "sending", and why.
    let lastWakeResult: String?
    let lastWakeReason: String?

    /// The same timer with new settings, shown optimistically until the dashboard answers. The
    /// schedule words and next due time stay the old ones until then (the dashboard computes them).
    func applying(pace: ChiefCheckInPace?, sleepCheckins: Bool?) -> ChiefCheckIn {
        let newPace = pace ?? self.pace
        return ChiefCheckIn(
            chiefKey: chiefKey, state: newPace == .quiet ? .quiet : (self.pace == .quiet ? .ok : state),
            lastCheckInAt: lastCheckInAt, runningSince: runningSince, nextDueAt: newPace == .quiet ? nil : nextDueAt,
            overdueSeconds: newPace == .quiet ? 0 : overdueSeconds, pace: newPace,
            sleepCheckins: sleepCheckins ?? self.sleepCheckins, schedule: schedule, wakeEnabled: wakeEnabled,
            lastWakeResult: lastWakeResult, lastWakeReason: lastWakeReason
        )
    }

    /// True when `pace`/`sleepCheckins` (nil = unchanged) would change nothing.
    func isUnchanged(pace: ChiefCheckInPace?, sleepCheckins: Bool?) -> Bool {
        (pace ?? self.pace) == self.pace && (sleepCheckins ?? self.sleepCheckins) == self.sleepCheckins
    }
}

/// The `checkIn` object on an `agentTree.chiefs[]` entry. Lenient: a bad field costs only itself.
struct ChiefCheckInWire: Decodable {
    let chiefKey: String?
    let state: String?
    let lastCheckInAt: Double?
    let checkInRunningSince: Double?
    let nextDueAt: Double?
    let overdueSec: Double?
    let pace: String?
    let sleepCheckins: Bool?
    let schedule: String?
    let wakeEnabled: Bool?
    let lastWake: LastWake?

    struct LastWake: Decodable {
        let result: String?
        let reason: String?

        private enum CodingKeys: String, CodingKey { case result, reason }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            result = container.lenient(.result)
            reason = container.lenient(.reason)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case chiefKey, state, lastCheckInAt, checkInRunningSince, nextDueAt, overdueSec, pace, sleepCheckins,
             schedule, wakeEnabled, lastWake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chiefKey = container.lenient(.chiefKey)
        state = container.lenient(.state)
        lastCheckInAt = container.lenient(.lastCheckInAt)
        checkInRunningSince = container.lenient(.checkInRunningSince)
        nextDueAt = container.lenient(.nextDueAt)
        overdueSec = container.lenient(.overdueSec)
        pace = container.lenient(.pace)
        sleepCheckins = container.lenient(.sleepCheckins)
        schedule = container.lenient(.schedule)
        wakeEnabled = container.lenient(.wakeEnabled)
        lastWake = container.lenient(.lastWake)
    }

    /// Nil without a chief key (nothing to change settings on) or a state this app can't read.
    var domain: ChiefCheckIn? {
        guard let chiefKey, !chiefKey.isEmpty, let state = state.flatMap(ChiefCheckIn.State.init(rawValue:)) else {
            return nil
        }
        return ChiefCheckIn(
            chiefKey: chiefKey, state: state,
            lastCheckInAt: lastCheckInAt.map(Date.init(timeIntervalSince1970:)),
            runningSince: checkInRunningSince.map(Date.init(timeIntervalSince1970:)),
            nextDueAt: nextDueAt.map(Date.init(timeIntervalSince1970:)),
            overdueSeconds: Int(overdueSec ?? 0),
            pace: pace.flatMap(ChiefCheckInPace.init(rawValue:)) ?? .steady,
            sleepCheckins: sleepCheckins ?? false,
            schedule: schedule ?? "",
            wakeEnabled: wakeEnabled ?? false,
            lastWakeResult: lastWake?.result, lastWakeReason: lastWake?.reason
        )
    }
}

/// Words for a chief's check-in, for its row badge and menu. Pure (clock + calendar passed in).
enum ChiefCheckInText {
    enum Tone: Equatable, Sendable { case ok, warn, danger, muted }

    /// The row badge: "Overdue 40m", "Check-in running", "Next 16:07", "Quiet", "Chief gone".
    static func badge(_ checkIn: ChiefCheckIn, now: Date, calendar: Calendar = .current) -> (text: String, tone: Tone) {
        if checkIn.runningSince != nil, checkIn.state == .ok || checkIn.state == .due {
            return ("Check-in running", .ok)
        }
        switch checkIn.state {
        case .overdue: return ("Overdue \(AgentAge.shortText(TimeInterval(checkIn.overdueSeconds)))", .danger)
        case .due: return ("Check-in due", .warn)
        case .ok:
            if let next = checkIn.nextDueAt { return ("Next \(clock(next, now: now, calendar: calendar))", .muted) }
            return ("No check-in due", .muted)
        case .quiet: return ("Check-ins quiet", .muted)
        case .gone: return ("Chief session gone", .muted)
        case .noSchedule: return ("No check-in schedule", .muted)
        case .error: return ("Check-in error", .warn)
        }
    }

    /// The menu's read-only lines: last, next, schedule, who wakes the chief, last wake.
    static func detailLines(_ checkIn: ChiefCheckIn, now: Date, calendar: Calendar = .current) -> [String] {
        var lines: [String] = []
        if let running = checkIn.runningSince {
            lines.append("Check-in running since \(clock(running, now: now, calendar: calendar))")
        }
        lines.append("Last check-in: " + (checkIn.lastCheckInAt.map { clock($0, now: now, calendar: calendar) } ?? "none seen"))
        if let next = checkIn.nextDueAt { lines.append("Next: \(clock(next, now: now, calendar: calendar))") }
        if !checkIn.schedule.isEmpty { lines.append("Schedule: \(checkIn.schedule)") }
        lines.append(checkIn.wakeEnabled
                     ? "The dashboard wakes this chief when a check-in is due"
                     : "Tracked only: the chief's own schedule wakes it")
        if let result = checkIn.lastWakeResult {
            let reason = checkIn.lastWakeReason.map { $0.isEmpty ? "" : " (\($0))" } ?? ""
            lines.append("Last wake: \(result)\(reason)")
        }
        return lines
    }

    /// "14:25" today, else "Mon 08:07". Always 24-hour, two-digit hours (the chief's cron words).
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}

/// Outcome of `POST /api/chief/settings`.
enum ChiefCheckInSettingsOutcome: Equatable, Sendable {
    case updated(ChiefCheckIn?)
    case failed(String)
}

/// `POST /api/chief/settings` reply: `{"ok":true,"settings":{…},"checkIn":{…}}` or
/// `{"ok":false,"error":str}`.
struct DashboardChiefSettingsResponse: Decodable {
    let ok: Bool?
    let error: String?
    let checkIn: ChiefCheckInWire?

    private enum CodingKeys: String, CodingKey { case ok, error, checkIn }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.lenient(.ok)
        error = container.lenient(.error)
        checkIn = container.lenient(.checkIn)
    }

    var outcome: ChiefCheckInSettingsOutcome {
        ok == true ? .updated(checkIn?.domain) : .failed(error ?? "The dashboard refused that change.")
    }
}
