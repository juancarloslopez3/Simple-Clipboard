import Foundation

/// An iCalendar file (`.ics`, `.vcs`) read for the Space preview: its events and
/// to-dos, with what the preview shows of each. Quick Look's calendar preview is a day grid that
/// shows only the title, at a fixed size that doesn't fit the card.
///
/// Covers RFC 5545 as invitations and exports use it: folded lines, escaped text, UTC / time-zone /
/// floating / all-day dates, `DURATION`, `RRULE`, `VALARM`, organizer and attendees, and meeting
/// links. A `TZID` that isn't an IANA name — the Windows names Outlook writes, such as "Romance
/// Standard Time" — is resolved with the file's own `VTIMEZONE` rules.
struct CalendarFile: Sendable {
    /// The calendar's name (`X-WR-CALNAME`), when the file has one.
    var name: String?
    /// Events and to-dos, earliest first (undated ones last).
    var events: [Event]

    struct Event: Identifiable, Sendable {
        let id: Int
        /// A `VTODO` rather than a `VEVENT`.
        var isTask = false
        var title = ""
        var start: Date?
        var end: Date?
        var isAllDay = false
        /// The zone the times were written in; nil for UTC and floating times.
        var timeZone: TimeZone?
        var location: String?
        var notes: String?
        /// The event's link, or its online meeting's.
        var url: URL?
        var organizer: Person?
        var attendees: [Attendee] = []
        var recurrence: Recurrence?
        /// Alerts, as offsets from the start (negative: before it).
        var alarms: [TimeInterval] = []
        var isCancelled = false
    }

    struct Person: Hashable, Sendable {
        var name: String?
        var email: String?

        /// The name, else the address.
        var displayName: String { name ?? email ?? "" }
    }

    struct Attendee: Hashable, Sendable {
        enum Response: Sendable { case accepted, declined, tentative, pending }
        var person: Person
        var response: Response
        var isOptional: Bool
    }

    struct Recurrence: Sendable {
        enum Frequency: Sendable { case daily, weekly, monthly, yearly }
        var frequency: Frequency
        var interval: Int
        /// `BYDAY` weekdays as `Calendar` numbers (1 = Sunday).
        var weekdays: [Int]
        var count: Int?
        var until: Date?
    }

    init?(data: Data) {
        guard let text = Self.decode(Self.unfolded(data)) else { return nil }
        let root = Self.components(in: text)
        guard let calendar = root.children.first(where: { $0.name == "VCALENDAR" }) ?? root.children.first,
              calendar.name == "VCALENDAR"
        else { return nil }

        let zones = Dictionary(calendar.children.filter { $0.name == "VTIMEZONE" }.compactMap { zone in
            zone.first("TZID").map { ($0.value, ZoneRules(zone)) }
        }, uniquingKeysWith: { first, _ in first })
        let isCancellation = calendar.first("METHOD")?.value.uppercased() == "CANCEL"
        name = calendar.first("X-WR-CALNAME").map { Self.unescaped($0.value) }.flatMap { $0.isEmpty ? nil : $0 }

        let parsed = calendar.children.enumerated().compactMap { index, component -> Event? in
            guard component.name == "VEVENT" || component.name == "VTODO" else { return nil }
            return Self.event(component, id: index, zones: zones, isCancellation: isCancellation)
        }
        guard !parsed.isEmpty else { return nil }
        events = parsed.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    // MARK: Events

    private static func event(_ component: Component, id: Int, zones: [String: ZoneRules], isCancellation: Bool) -> Event {
        var event = Event(id: id)
        event.isTask = component.name == "VTODO"
        event.title = component.first("SUMMARY").map { unescaped($0.value) } ?? ""
        let startProperty = component.first("DTSTART") ?? (event.isTask ? component.first("DUE") : nil)
        if let startProperty, let start = date(startProperty, zones: zones) {
            event.start = start.date
            event.isAllDay = start.isAllDay
            event.timeZone = start.zone
            if let endProperty = component.first(event.isTask ? "DUE" : "DTEND"), endProperty !== startProperty,
               let end = date(endProperty, zones: zones), end.date >= start.date {
                event.end = end.date
            } else if let duration = component.first("DURATION").flatMap({ Self.duration($0.value) }) {
                event.end = start.date.addingTimeInterval(duration)
            } else if start.isAllDay {
                // An all-day event without an end lasts its one day.
                event.end = Calendar.current.date(byAdding: .day, value: 1, to: start.date)
            }
        }
        event.location = component.first("LOCATION").map { unescaped($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        event.notes = component.first("DESCRIPTION").map { unescaped($0.value) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let links = ["URL", "CONFERENCE", "X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "X-MICROSOFT-ONLINEMEETINGCONFLINK"]
        event.url = links.lazy.compactMap { component.first($0) }
            .compactMap { URL(string: unescaped($0.value).trimmingCharacters(in: .whitespaces)) }
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        event.organizer = component.first("ORGANIZER").map(person)
        event.attendees = component.all("ATTENDEE").map { property in
            let response: Attendee.Response = switch property.parameters["PARTSTAT"]?.uppercased() {
            case "ACCEPTED", "COMPLETED": .accepted
            case "DECLINED": .declined
            case "TENTATIVE": .tentative
            default: .pending
            }
            return Attendee(person: person(property), response: response,
                            isOptional: ["OPT-PARTICIPANT", "NON-PARTICIPANT"].contains(property.parameters["ROLE"]?.uppercased() ?? ""))
        }
        // The organizer often lists themselves among the attendees too.
        if let organizer = event.organizer?.email?.lowercased() {
            event.attendees.removeAll { $0.person.email?.lowercased() == organizer }
        }
        event.recurrence = component.first("RRULE").flatMap { recurrence($0.value, zones: zones) }
        event.alarms = component.children.filter { $0.name == "VALARM" }.compactMap { alarm in
            guard let trigger = alarm.first("TRIGGER") else { return nil }
            if trigger.parameters["VALUE"]?.uppercased() == "DATE-TIME" {
                guard let start = event.start, let moment = date(trigger, zones: zones) else { return nil }
                return moment.date.timeIntervalSince(start)
            }
            return duration(trigger.value)
        }
        event.alarms = Array(Set(event.alarms)).sorted()
        event.isCancelled = isCancellation || component.first("STATUS")?.value.uppercased() == "CANCELLED"
        return event
    }

    private static func person(_ property: Property) -> Person {
        var value = property.value
        if value.lowercased().hasPrefix("mailto:") { value.removeFirst("mailto:".count) }
        let name = property.parameters["CN"].map(unescaped).flatMap { $0.isEmpty ? nil : $0 }
        let email = value.contains("@") ? value : nil
        // A CN that is just the address adds nothing.
        return Person(name: name?.lowercased() == email?.lowercased() ? nil : name, email: email)
    }

    private static func recurrence(_ rule: String, zones: [String: ZoneRules]) -> Recurrence? {
        var parts: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0].uppercased()] = pair[1] }
        }
        let frequency: Recurrence.Frequency
        switch parts["FREQ"]?.uppercased() {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default: return nil
        }
        let weekdays = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { weekday(String($0).suffix(2)) }
        let until = parts["UNTIL"].flatMap { date(Property(name: "UNTIL", parameters: [:], value: $0), zones: zones)?.date }
        return Recurrence(frequency: frequency, interval: max(Int(parts["INTERVAL"] ?? "") ?? 1, 1),
                          weekdays: weekdays, count: parts["COUNT"].flatMap { Int($0) }, until: until)
    }

    private static func weekday(_ code: some StringProtocol) -> Int? {
        ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7][code.uppercased()]
    }

    // MARK: Dates

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    /// A calendar that reads wall-clock times as if they were UTC, for zone arithmetic.
    private static let wallClock: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    /// The wall-clock parts of `20261110T100000` / `20261110`, and whether it ended in `Z`.
    private static func dateParts(_ value: String) -> (parts: DateComponents, hasTime: Bool, isUTC: Bool)? {
        let digits = value.trimmingCharacters(in: .whitespaces)
        let characters = Array(digits)
        guard characters.count >= 8, let year = Int(String(characters[0..<4])),
              let month = Int(String(characters[4..<6])), let day = Int(String(characters[6..<8]))
        else { return nil }
        var parts = DateComponents(year: year, month: month, day: day)
        guard characters.count >= 15, characters[8] == "T",
              let hour = Int(String(characters[9..<11])), let minute = Int(String(characters[11..<13])),
              let second = Int(String(characters[13..<15]))
        else { return (parts, false, false) }
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return (parts, true, characters.count > 15 && characters[15] == "Z")
    }

    private static func date(_ property: Property, zones: [String: ZoneRules]) -> (date: Date, isAllDay: Bool, zone: TimeZone?)? {
        guard let (parts, hasTime, isUTC) = dateParts(property.value) else { return nil }
        if !hasTime || property.parameters["VALUE"]?.uppercased() == "DATE" {
            // An all-day date is a calendar day wherever the viewer is.
            return Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
                .map { ($0, true, nil) }
        }
        if isUTC { return wallClock.date(from: parts).map { ($0, false, nil) } }
        guard let tzid = property.parameters["TZID"], !tzid.isEmpty else {
            // Floating: the same wall-clock time in every zone.
            return Calendar.current.date(from: parts).map { ($0, false, nil) }
        }
        if let zone = ianaZone(tzid) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: parts).map { ($0, false, zone) }
        }
        guard let wall = wallClock.date(from: parts) else { return nil }
        if let offset = zones[tzid]?.offset(atWallClock: wall) {
            return (wall.addingTimeInterval(-TimeInterval(offset)), false, TimeZone(secondsFromGMT: offset))
        }
        return Calendar.current.date(from: parts).map { ($0, false, nil) }
    }

    /// An IANA zone for a `TZID`, including the path-prefixed ones some exporters write
    /// (`/mozilla.org/20050126_1/Europe/Madrid`).
    private static func ianaZone(_ tzid: String) -> TimeZone? {
        if let zone = TimeZone(identifier: tzid) { return zone }
        let components = tzid.split(separator: "/")
        for length in [3, 2] where components.count > length {
            if let zone = TimeZone(identifier: components.suffix(length).joined(separator: "/")) { return zone }
        }
        return nil
    }

    /// An ISO 8601 duration (`-PT15M`, `P1DT2H`, `P2W`) in seconds.
    static func duration(_ value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: Double = 1
        if text.first == "-" { sign = -1; text.removeFirst() } else if text.first == "+" { text.removeFirst() }
        guard text.first == "P" else { return nil }
        text.removeFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        for character in text {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", _): total += amount * 604_800
            case ("D", _): total += amount * 86_400
            case ("H", true): total += amount * 3_600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        return number.isEmpty ? sign * total : nil
    }

    /// A `VTIMEZONE`'s observances, enough to find the UTC offset of a wall-clock time: each
    /// `STANDARD` / `DAYLIGHT` part starts on its `DTSTART` and, with a yearly `RRULE`
    /// (`BYMONTH=10;BYDAY=-1SU`), again every year.
    private struct ZoneRules: Sendable {
        struct Observance: Sendable {
            var start: Date
            var offsetFrom: Int
            var offsetTo: Int
            var month: Int?
            /// `BYDAY`: which weekday of the month (-1 = the last), and the weekday.
            var ordinal: Int?
            var weekday: Int?
            var until: Date?
        }

        var observances: [Observance] = []

        init(_ zone: Component) {
            observances = zone.children.compactMap { part in
                guard part.name == "STANDARD" || part.name == "DAYLIGHT",
                      let start = part.first("DTSTART").flatMap({ CalendarFile.dateParts($0.value) }),
                      let startDate = CalendarFile.wallClock.date(from: start.parts),
                      let to = part.first("TZOFFSETTO").flatMap({ ZoneRules.offset($0.value) })
                else { return nil }
                var observance = Observance(start: startDate, offsetFrom: part.first("TZOFFSETFROM").flatMap { ZoneRules.offset($0.value) } ?? to,
                                            offsetTo: to)
                if let rule = part.first("RRULE")?.value.uppercased(), rule.contains("FREQ=YEARLY") {
                    for item in rule.split(separator: ";") {
                        let pair = item.split(separator: "=", maxSplits: 1)
                        guard pair.count == 2 else { continue }
                        switch pair[0] {
                        case "BYMONTH": observance.month = Int(pair[1].split(separator: ",").first ?? "")
                        case "BYDAY":
                            let day = pair[1].split(separator: ",").first.map(String.init) ?? ""
                            observance.weekday = CalendarFile.weekday(day.suffix(2))
                            observance.ordinal = Int(day.dropLast(2)) ?? 1
                        case "UNTIL":
                            observance.until = CalendarFile.dateParts(String(pair[1])).flatMap { CalendarFile.wallClock.date(from: $0.parts) }
                        default: break
                        }
                    }
                }
                return observance
            }
        }

        /// `+0200`, `-0530`, `+013045` in seconds east of UTC.
        static func offset(_ value: String) -> Int? {
            let text = value.trimmingCharacters(in: .whitespaces)
            guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
            let digits = Array(text.dropFirst())
            guard digits.count >= 4, let hours = Int(String(digits[0..<2])), let minutes = Int(String(digits[2..<4])) else { return nil }
            let seconds = digits.count >= 6 ? Int(String(digits[4..<6])) ?? 0 : 0
            return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds)
        }

        /// The offset in effect at `wall` (a wall-clock time read as UTC): the observance that
        /// started most recently before it.
        func offset(atWallClock wall: Date) -> Int? {
            guard !observances.isEmpty else { return nil }
            let year = CalendarFile.wallClock.component(.year, from: wall)
            var latest: (onset: Date, offset: Int)?
            for observance in observances {
                for onset in onsets(of: observance, years: [year - 1, year]) where onset <= wall {
                    if latest.map({ onset > $0.onset }) ?? true { latest = (onset, observance.offsetTo) }
                }
            }
            return latest?.offset ?? observances.min(by: { $0.start < $1.start })?.offsetFrom
        }

        private func onsets(of observance: Observance, years: [Int]) -> [Date] {
            guard let month = observance.month, let weekday = observance.weekday else { return [observance.start] }
            let calendar = CalendarFile.wallClock
            let time = calendar.dateComponents([.hour, .minute, .second], from: observance.start)
            return years.compactMap { year -> Date? in
                guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let days = calendar.range(of: .day, in: .month, for: first)
                else { return nil }
                let matching = days.compactMap { day -> Int? in
                    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
                    return calendar.component(.weekday, from: date) == weekday ? day : nil
                }
                let ordinal = observance.ordinal ?? 1
                let index = ordinal > 0 ? ordinal - 1 : matching.count + ordinal
                guard matching.indices.contains(index) else { return nil }
                let onset = calendar.date(from: DateComponents(year: year, month: month, day: matching[index],
                                                               hour: time.hour, minute: time.minute, second: time.second))
                guard let onset, onset >= observance.start, observance.until.map({ onset <= $0 }) ?? true else { return nil }
                return onset
            }
        }
    }

    // MARK: Content lines

    private final class Component: @unchecked Sendable {
        let name: String
        var properties: [Property] = []
        var children: [Component] = []

        init(name: String) { self.name = name }

        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        func all(_ name: String) -> [Property] { properties.filter { $0.name == name } }
    }

    private final class Property: @unchecked Sendable {
        let name: String
        let parameters: [String: String]
        let value: String

        init(name: String, parameters: [String: String], value: String) {
            self.name = name
            self.parameters = parameters
            self.value = value
        }
    }

    /// Removes line folding (a line break followed by a space or tab) at the byte level, so a
    /// multi-byte character folded across two lines comes back whole.
    private static func unfolded(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D, index + 2 < bytes.count, bytes[index + 1] == 0x0A, bytes[index + 2] == 0x20 || bytes[index + 2] == 0x09 {
                index += 3
            } else if byte == 0x0A, index + 1 < bytes.count, bytes[index + 1] == 0x20 || bytes[index + 1] == 0x09 {
                index += 2
            } else {
                result.append(byte)
                index += 1
            }
        }
        return Data(result)
    }

    private static func decode(_ data: Data) -> String? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// The component tree: a root holding the file's top-level components.
    private static func components(in text: String) -> Component {
        let root = Component(name: "")
        var stack = [root]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let property = property(String(line)) else { continue }
            switch property.name {
            case "BEGIN":
                let component = Component(name: property.value.uppercased())
                stack.last?.children.append(component)
                stack.append(component)
            case "END":
                if stack.count > 1 { stack.removeLast() }
            default:
                stack.last?.properties.append(property)
            }
        }
        return root
    }

    /// `NAME;PARAM=value;PARAM="quoted:value":the value`.
    private static func property(_ line: String) -> Property? {
        var inQuotes = false
        var nameAndParameters: [String] = []
        var current = ""
        var valueStart: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, character == ";" {
                nameAndParameters.append(current)
                current = ""
                continue
            }
            if !inQuotes, character == ":" {
                nameAndParameters.append(current)
                valueStart = line.index(after: index)
                break
            }
            current.append(character)
        }
        guard let valueStart, let name = nameAndParameters.first, !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for parameter in nameAndParameters.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parameters[pair[0].uppercased()] = pair[1] }
        }
        return Property(name: name.uppercased(), parameters: parameters, value: String(line[valueStart...]))
    }

    /// TEXT values escape `\n`, `\,`, `\;` and `\\`.
    static func unescaped(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
