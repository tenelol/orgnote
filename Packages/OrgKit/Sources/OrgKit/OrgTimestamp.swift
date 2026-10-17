import Foundation

/// A calendar day without time zone, as written in Org timestamps.
public struct OrgDate: Hashable, Comparable, Sendable, Codable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Arithmetic runs in UTC so daylight saving never shifts a day.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    var utcDate: Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func date(calendar: Calendar = .current, time: OrgTime? = nil) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: time?.hour ?? 0, minute: time?.minute ?? 0
        )) ?? .distantPast
    }

    public func adding(days: Int) -> OrgDate {
        adding(days, .day)
    }

    public func adding(_ value: Int, _ unit: OrgRepeater.Unit) -> OrgDate {
        let component: Calendar.Component = switch unit {
        case .hour, .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        // Hour repeaters only make sense with a time; a day is the closest calendar step.
        let date = Self.utc.date(byAdding: component, value: value, to: utcDate)!
        return OrgDate(date, calendar: Self.utc)
    }

    public func days(until other: OrgDate) -> Int {
        Self.utc.dateComponents([.day], from: utcDate, to: other.utcDate).day ?? 0
    }

    /// English abbreviations keep files identical to what Emacs and nvim-orgmode write.
    public var weekdayAbbreviation: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names[Self.utc.component(.weekday, from: utcDate) - 1]
    }

    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: OrgDate, rhs: OrgDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public struct OrgTime: Hashable, Comparable, Sendable, Codable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    public var string: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: OrgTime, rhs: OrgTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

public struct OrgRepeater: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case cumulate = "+"
        case catchUp = "++"
        case restart = ".+"
    }

    public enum Unit: String, Sendable {
        case hour = "h", day = "d", week = "w", month = "m", year = "y"
    }

    public var kind: Kind
    public var value: Int
    public var unit: Unit

    public var string: String { "\(kind.rawValue)\(value)\(unit.rawValue)" }

    /// The next date after completing the task on `today`, following Org semantics.
    public func next(after date: OrgDate, today: OrgDate) -> OrgDate {
        switch kind {
        case .cumulate:
            return date.adding(value, unit)
        case .catchUp:
            var next = date.adding(value, unit)
            while next <= today { next = next.adding(value, unit) }
            return next
        case .restart:
            return today.adding(value, unit)
        }
    }
}

public struct OrgTimestamp: Hashable, Sendable {
    public var date: OrgDate
    public var time: OrgTime?
    public var endTime: OrgTime?
    public var isActive: Bool
    public var repeater: OrgRepeater?
    /// Warning or delay cookies such as `-3d`, kept verbatim.
    public var warning: String?

    public init(
        date: OrgDate, time: OrgTime? = nil, endTime: OrgTime? = nil,
        isActive: Bool = true, repeater: OrgRepeater? = nil, warning: String? = nil
    ) {
        self.date = date
        self.time = time
        self.endTime = endTime
        self.isActive = isActive
        self.repeater = repeater
        self.warning = warning
    }

    public static func now(active: Bool = false, includeTime: Bool = true, at date: Date = .now) -> OrgTimestamp {
        OrgTimestamp(date: OrgDate(date), time: includeTime ? OrgTime(date) : nil, isActive: active)
    }

    public var string: String {
        var parts = [date.isoString, date.weekdayAbbreviation]
        if let time {
            parts.append(endTime.map { "\(time.string)-\($0.string)" } ?? time.string)
        }
        if let repeater { parts.append(repeater.string) }
        if let warning { parts.append(warning) }
        let body = parts.joined(separator: " ")
        return isActive ? "<\(body)>" : "[\(body)]"
    }

    static let regex = try! NSRegularExpression(pattern:
        #"([<\[])(\d{4})-(\d{2})-(\d{2})(?:[ \t]+[^\s\d>\]+.\-]+)?"#
        + #"(?:[ \t]+(\d{1,2}):(\d{2})(?:-(\d{1,2}):(\d{2}))?)?"#
        + #"((?:[ \t]+(?:\.\+|\+\+|\+|--|-)\d+[hdwmy])*)[ \t]*([>\]])"#)

    /// Every timestamp in `string` with its UTF-16 range.
    public static func all(in string: String) -> [(range: NSRange, timestamp: OrgTimestamp)] {
        let ns = string as NSString
        return regex.matches(in: string, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            parse(match: match, in: ns).map { (match.range, $0) }
        }
    }

    public static func parse(_ string: String) -> OrgTimestamp? {
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              match.range.length == ns.length
        else { return nil }
        return parse(match: match, in: ns)
    }

    private static func parse(match: NSTextCheckingResult, in ns: NSString) -> OrgTimestamp? {
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let open = group(1), close = group(10)
        guard (open == "<" && close == ">") || (open == "[" && close == "]"),
              let year = group(2).flatMap(Int.init),
              let month = group(3).flatMap(Int.init),
              let day = group(4).flatMap(Int.init),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var timestamp = OrgTimestamp(date: OrgDate(year: year, month: month, day: day), isActive: open == "<")
        if let h = group(5).flatMap(Int.init), let m = group(6).flatMap(Int.init) {
            timestamp.time = OrgTime(hour: h, minute: m)
        }
        if let h = group(7).flatMap(Int.init), let m = group(8).flatMap(Int.init) {
            timestamp.endTime = OrgTime(hour: h, minute: m)
        }
        var warnings: [String] = []
        for cookie in (group(9) ?? "").split(whereSeparator: \.isWhitespace).map(String.init) {
            if let repeater = parseRepeater(cookie) {
                timestamp.repeater = repeater
            } else {
                warnings.append(cookie)
            }
        }
        timestamp.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return timestamp
    }

    private static func parseRepeater(_ cookie: String) -> OrgRepeater? {
        let kind: OrgRepeater.Kind
        var rest = Substring(cookie)
        if rest.hasPrefix(".+") { kind = .restart; rest = rest.dropFirst(2) }
        else if rest.hasPrefix("++") { kind = .catchUp; rest = rest.dropFirst(2) }
        else if rest.hasPrefix("+") { kind = .cumulate; rest = rest.dropFirst() }
        else { return nil }
        guard let unitChar = rest.last, let unit = OrgRepeater.Unit(rawValue: String(unitChar)),
              let value = Int(rest.dropLast())
        else { return nil }
        return OrgRepeater(kind: kind, value: value, unit: unit)
    }
}
