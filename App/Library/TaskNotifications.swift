import OrgKit
import UIKit
import UserNotifications

/// A notification set from the capture sheet. It lives only in the app, so
/// the Org files stay exactly as written; the entry is found again by title.
struct Reminder: Codable, Identifiable, Hashable {
    var id = UUID()
    var fileID: String
    var title: String
    var date: Date
}

/// Local notifications for the entries given one in the app. They are kept
/// in this device's settings and handed to iOS, skipping entries since done.
@MainActor @Observable
final class TaskNotifications: NSObject {
    static let shared = TaskNotifications()
    private static let key = "reminders"
    /// iOS keeps at most 64 pending notifications per app.
    private static let limit = 60

    private(set) var reminders: [Reminder]
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var scheduled: [String: Date] = [:]
    @ObservationIgnored private var synced = false

    override init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        reminders = data.flatMap { try? JSONDecoder().decode([Reminder].self, from: $0) } ?? []
        super.init()
    }

    func start() {
        center.delegate = self
    }

    /// Adds a notification, asking for permission the first time.
    func add(_ reminder: Reminder) {
        reminders.append(reminder)
        reminders.sort { $0.date < $1.date }
        save()
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted { reschedule(LibraryStore.shared) }
        }
    }

    func remove(_ reminder: Reminder) {
        reminders.removeAll { $0.id == reminder.id }
        save()
        reschedule(LibraryStore.shared)
    }

    /// Hands iOS the reminders still ahead whose entry is not done.
    func reschedule(_ store: LibraryStore, now: Date = .now) {
        // Delivered ones are done with.
        if reminders.contains(where: { $0.date <= now }) {
            reminders.removeAll { $0.date <= now }
            save()
        }
        let wanted = reminders
            .filter { reminder in !(headline(for: reminder, in: store).map { $0.1.isDone } ?? false) }
            .prefix(Self.limit)

        // The store refreshes every few seconds, so touch only what changed. Clearing
        // everything would also drop a notification in the instant it is due.
        let plan = Dictionary(wanted.map { ($0.id.uuidString, $0.date) }, uniquingKeysWith: { a, _ in a })
        if !synced {
            // Requests left by an earlier run may belong to reminders since removed.
            center.removeAllPendingNotificationRequests()
            scheduled = [:]
            synced = true
        }
        let stale = scheduled.filter { plan[$0.key] != $0.value && $0.value > now }.map(\.key)
        let added = wanted.filter { scheduled[$0.id.uuidString] != $0.date }
        scheduled = plan
        guard !stale.isEmpty || !added.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for reminder in added {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.id.uuidString,
                                             content: content(for: reminder, in: store), trigger: trigger))
        }
    }

    /// The entry by title: in its notebook first, then anywhere, since it may have been moved.
    func headline(for reminder: Reminder, in store: LibraryStore) -> (String, OrgHeadline)? {
        let files = [store.files[reminder.fileID]].compactMap { $0 } + store.sortedFiles
        for file in files {
            if let headline = file.document.headlines.first(where: { $0.title == reminder.title }) {
                return (file.id, headline)
            }
        }
        return nil
    }

    private func content(for reminder: Reminder, in store: LibraryStore) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.title.isEmpty ? "無題" : reminder.title
        let fileID = headline(for: reminder, in: store)?.0 ?? reminder.fileID
        content.body = store.files[fileID]?.displayName ?? (fileID as NSString).deletingPathExtension
        content.sound = .default
        content.threadIdentifier = fileID
        content.userInfo = ["fileID": reminder.fileID, "title": reminder.title]
        return content
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(reminders), forKey: Self.key)
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

    /// Opens the entry the notification is about, wherever it is now.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let fileID = info["fileID"] as? String, let title = info["title"] as? String {
            let found = headline(for: Reminder(fileID: fileID, title: title, date: .now), in: LibraryStore.shared)
            var parts = URLComponents()
            parts.scheme = "orgnote"
            parts.host = "file"
            parts.queryItems = [URLQueryItem(name: "id", value: found?.0 ?? fileID)]
                + (found.map { [URLQueryItem(name: "line", value: String($0.1.lineIndex))] } ?? [])
            AppRouter.shared.pendingLink = parts.url
        }
        completionHandler()
    }
}
