import Foundation

public struct AgendaItem: Hashable, Sendable, Identifiable {
    public enum Kind: Int, Hashable, Sendable, Comparable {
        case timestamp, deadline, scheduled

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var fileID: String
    public var headline: OrgHeadline
    public var kind: Kind
    public var date: OrgDate
    public var time: OrgTime?

    public var id: String { "\(fileID)#\(headline.identity)#\(kind)#\(date.isoString)" }
}

public struct AgendaDay: Hashable, Sendable, Identifiable {
    public var date: OrgDate
    public var items: [AgendaItem]
    public var id: OrgDate { date }
}

public struct Agenda: Sendable {
    /// Unfinished scheduled items and deadlines from before today.
    public var overdue: [AgendaItem]
    public var days: [AgendaDay]
    /// Open TODOs without any date.
    public var unscheduled: [AgendaItem]

    public var todayCount: Int {
        overdue.count + (days.first?.items.filter { !$0.headline.isDone }.count ?? 0)
    }

    public init(documents: [(id: String, document: OrgDocument)], today: OrgDate, days dayCount: Int = 7) {
        let end = today.adding(days: dayCount - 1)
        var overdue: [AgendaItem] = []
        var byDay: [OrgDate: [AgendaItem]] = [:]
        var unscheduled: [AgendaItem] = []

        for (fileID, document) in documents {
            for headline in document.headlines {
                func item(_ kind: AgendaItem.Kind, _ date: OrgDate, _ time: OrgTime?) -> AgendaItem {
                    AgendaItem(fileID: fileID, headline: headline, kind: kind, date: date, time: time)
                }

                var dated = false
                for (kind, timestamp) in [(AgendaItem.Kind.scheduled, headline.scheduled), (.deadline, headline.deadline)] {
                    guard let timestamp else { continue }
                    dated = true
                    if timestamp.date < today {
                        if !headline.isDone, headline.keyword != nil || kind == .deadline {
                            overdue.append(item(kind, timestamp.date, timestamp.time))
                        }
                        // A repeating entry still shows its future occurrences.
                        if timestamp.repeater == nil { continue }
                    }
                    for date in Self.occurrences(of: timestamp, from: today, through: end) where date >= today {
                        byDay[date, default: []].append(item(kind, date, timestamp.time))
                    }
                }
                for timestamp in headline.timestamps {
                    for date in Self.occurrences(of: timestamp, from: today, through: end) {
                        byDay[date, default: []].append(item(.timestamp, date, timestamp.time))
                    }
                }
                if !dated, headline.isTodo {
                    unscheduled.append(item(.scheduled, today, nil))
                }
            }
        }

        func order(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
            switch (a.time, b.time) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.headline.isDone != b.headline.isDone { return !a.headline.isDone }
            if a.kind != b.kind { return a.kind < b.kind }
            let pa = a.headline.priority ?? "~", pb = b.headline.priority ?? "~"
            if pa != pb { return pa < pb }
            return (a.fileID, a.headline.lineIndex) < (b.fileID, b.headline.lineIndex)
        }

        self.overdue = overdue.sorted { ($0.date, $0.kind) < ($1.date, $1.kind) }
        self.days = (0..<dayCount).map { offset in
            let date = today.adding(days: offset)
            return AgendaDay(date: date, items: (byDay[date] ?? []).sorted(by: order))
        }
        self.unscheduled = unscheduled.sorted {
            ($0.headline.priority ?? "~", $0.fileID, $0.headline.lineIndex)
                < ($1.headline.priority ?? "~", $1.fileID, $1.headline.lineIndex)
        }
    }

    static func occurrences(of timestamp: OrgTimestamp, from start: OrgDate, through end: OrgDate) -> [OrgDate] {
        guard timestamp.date <= end else { return [] }
        guard let repeater = timestamp.repeater, repeater.value > 0 else {
            return timestamp.date >= start ? [timestamp.date] : []
        }
        var dates: [OrgDate] = []
        var date = timestamp.date
        // Bounded so a malformed repeater cannot loop forever.
        for _ in 0..<5000 where date <= end {
            if date >= start { dates.append(date) }
            let next = date.adding(repeater.value, repeater.unit)
            if next <= date { break }
            date = next
        }
        return dates
    }
}
