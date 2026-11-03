import EventKit
import Observation
import OrgKit
import UIKit

/// One event from the system calendars, kept small so the agenda can hold a
/// year of them without touching EventKit on every redraw.
struct CalendarEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: UIColor
    var calendar: String

    var time: OrgTime? { isAllDay ? nil : OrgTime(start) }
}

/// Read-only events from the calendars on this iPhone, including Google
/// accounts added in Settings › Calendar, shown beside Org tasks.
@MainActor @Observable
final class CalendarEvents {
    static let shared = CalendarEvents()
    private static let enabledKey = "showCalendarEvents"
    private static let hiddenKey = "hiddenCalendars"

    private let store = EKEventStore()
    private(set) var byDay: [OrgDate: [CalendarEvent]] = [:]
    private(set) var calendars: [EKCalendar] = []
    private(set) var hidden: Set<String>
    private(set) var isEnabled: Bool
    @ObservationIgnored private var loadedFor: OrgDate?

    /// How far the cache reaches either side of today; matches the agenda strip.
    static let reach = 180

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Turns the feature on, asking for access the first time. Returns false when refused.
    func setEnabled(_ on: Bool) async -> Bool {
        if on, !isAuthorized {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            guard granted else { return false }
        }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        reload()
        return true
    }

    func setHidden(_ calendar: EKCalendar, _ isHidden: Bool) {
        if isHidden { hidden.insert(calendar.calendarIdentifier) } else { hidden.remove(calendar.calendarIdentifier) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenKey)
        reload()
    }

    /// Refreshes when the day has turned since the last load, e.g. on returning to the app.
    func reloadIfStale() {
        if loadedFor != OrgDate(.now) { reload() }
    }

    func reload() {
        guard isEnabled, isAuthorized else {
            byDay = [:]
            calendars = []
            return
        }
        store.refreshSourcesIfNecessary()
        calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
        let today = OrgDate(.now)
        loadedFor = today
        let shown = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else {
            byDay = [:]
            return
        }
        let start = today.adding(days: -Self.reach).date()
        let end = today.adding(days: Self.reach + 1).date()
        var days: [OrgDate: [CalendarEvent]] = [:]
        for event in store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: shown)) {
            let item = CalendarEvent(
                id: "\(event.calendarItemIdentifier)#\(event.startDate.timeIntervalSince1970)",
                title: event.title?.isEmpty == false ? event.title : String(localized: "Untitled"),
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                color: event.calendar.cgColor.map(UIColor.init(cgColor:)) ?? .systemGray,
                calendar: event.calendar.title)
            // A multi-day event shows on every day it covers; its end is exclusive.
            var day = OrgDate(event.startDate)
            let last = OrgDate(event.endDate.addingTimeInterval(event.isAllDay || event.endDate > event.startDate ? -1 : 0))
            var count = 0
            while day <= last, count < 62 {
                days[day, default: []].append(item)
                day = day.adding(days: 1)
                count += 1
            }
        }
        for key in days.keys {
            days[key]?.sort { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        }
        byDay = days
    }
}
