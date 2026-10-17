import OrgKit
import UIKit
import UserNotifications

/// Local notifications for entries with a time, such as
/// `SCHEDULED: <2026-10-20 Tue 10:00>`. They are rebuilt from the files
/// whenever the app sees a change, so edits made on the Mac arrive the next
/// time Orgnote runs.
@MainActor
final class TaskNotifications: NSObject {
    static let shared = TaskNotifications()
    static let enabledKey = "notificationsEnabled"
    static let leadKey = "notificationLeadMinutes"
    /// iOS keeps at most 64 pending notifications per app.
    private static let limit = 60
    /// How far ahead to look; the next run of the app tops the list up.
    private static let horizon = 14

    private let center = UNUserNotificationCenter.current()
    private var scheduled: [String: Date] = [:]
    private var synced = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var leadMinutes: Int { UserDefaults.standard.integer(forKey: Self.leadKey) }

    func start() {
        center.delegate = self
    }

    /// Turns notifications on, asking for permission the first time. Returns false when refused.
    func setEnabled(_ on: Bool) async -> Bool {
        if on {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return false }
        } else {
            center.removeAllPendingNotificationRequests()
        }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        scheduled = [:]
        synced = false
        reschedule(LibraryStore.shared)
        return true
    }

    func setLead(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: Self.leadKey)
        reschedule(LibraryStore.shared)
    }

    /// Replaces the pending notifications with the open timed entries ahead.
    func reschedule(_ store: LibraryStore, now: Date = .now) {
        guard isEnabled else { return }
        let lead = TimeInterval(leadMinutes * 60)
        var wanted: [(id: String, fire: Date, content: UNMutableNotificationContent)] = []
        for day in store.agenda(from: OrgDate(now), days: Self.horizon).days {
            for item in day.items where !item.headline.isDone {
                guard let time = item.time else { continue }
                let at = item.date.date(time: time)
                let fire = at.addingTimeInterval(-lead)
                guard fire > now else { continue }
                wanted.append((item.id, fire, content(for: item, at: at, in: store)))
            }
        }
        wanted.sort { $0.fire < $1.fire }
        wanted = Array(wanted.prefix(Self.limit))

        // The store refreshes every few seconds, so touch only what changed. Clearing
        // everything would also drop a notification in the instant it is due.
        let plan = Dictionary(wanted.map { ($0.id, $0.fire) }, uniquingKeysWith: { a, _ in a })
        if !synced {
            // Requests left by an earlier run may belong to entries that no longer exist.
            center.removeAllPendingNotificationRequests()
            scheduled = [:]
            synced = true
        }
        let stale = scheduled.filter { plan[$0.key] != $0.value && $0.value > now }.map(\.key)
        let added = wanted.filter { scheduled[$0.id] != $0.fire }
        scheduled = plan
        guard !stale.isEmpty || !added.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for entry in added {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: entry.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: entry.id, content: entry.content, trigger: trigger))
        }
    }

    private func content(for item: AgendaItem, at date: Date, in store: LibraryStore) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let title = item.headline.displayTitle
        content.title = title.isEmpty ? "無題" : title
        let kind = switch item.kind {
        case .deadline: "期限"
        case .scheduled: "予定"
        case .timestamp: "予定"
        }
        let place = store.files[item.fileID]?.displayName ?? item.fileID
        content.body = "\(kind) \(item.time?.string ?? "") · \(place)"
        content.sound = .default
        content.threadIdentifier = item.fileID
        content.userInfo = ["fileID": item.fileID, "line": item.headline.lineIndex]
        return content
    }
}

// Main-actor isolated: the async variants of these methods finish off the main
// thread, which trips a UIKit assertion when a tapped notification opens the app.
extension TaskNotifications: @preconcurrency UNUserNotificationCenterDelegate {
    /// Shows the banner even while Orgnote is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Opens the entry the notification is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let fileID = info["fileID"] as? String {
            var parts = URLComponents()
            parts.scheme = "orgnote"
            parts.host = "file"
            parts.queryItems = [URLQueryItem(name: "id", value: fileID)]
                + ((info["line"] as? Int).map { [URLQueryItem(name: "line", value: String($0))] } ?? [])
            AppRouter.shared.pendingLink = parts.url
        }
        completionHandler()
    }
}
