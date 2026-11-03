import EventKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(CalendarEvents.self) private var events
    @AppStorage("captureAsTodo") private var asTodo = false
    @State private var picking = false
    @State private var calendarDenied = false
    @State private var notificationsBlocked = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location", value: store.locationDescription)
                    Button("Choose Another Folder…") { picking = true }
                    if store.storage == nil {
                        Button("Return to Orgnote Folder") { Task { await store.useAppFolder() } }
                    }
                } footer: {
                    Text("Notebooks are .org files. Choose a folder in iCloud Drive to keep them in sync with a folder like ~/org on your computer.")
                }

                Section("New Memo") {
                    Picker("Save To", selection: $store.inboxPath) {
                        if store.files[store.inboxPath] == nil {
                            Text(store.inboxPath).tag(store.inboxPath)
                        }
                        ForEach(store.sortedFiles.filter { !$0.isPlaceholder }) { file in
                            Text(file.id).tag(file.id)
                        }
                    }
                    Toggle("Start as To-do", isOn: $asTodo)
                }

                Section {
                    Toggle("Show Calendar Events", isOn: Binding {
                        events.isEnabled
                    } set: { on in
                        Task {
                            if await !events.setEnabled(on) { calendarDenied = true }
                        }
                    })
                    if events.isEnabled {
                        NavigationLink("Calendars to Show") { CalendarChoice() }
                    }
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("Add your Google account in Settings › Apps › Calendar › Calendar Accounts to see Google Calendar events in the agenda too. Events are only read, never changed.")
                }

                Section {
                    if notificationsBlocked {
                        Button("Allow Notifications…") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    ForEach(TaskNotifications.shared.reminders) { reminder in
                        LabeledContent(reminder.title.isEmpty ? String(localized: "Untitled") : reminder.title,
                                       value: reminder.date.formatted(.dateTime.month().day().hour().minute()))
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    TaskNotifications.shared.remove(reminder)
                                }
                            }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Set reminders with Add Reminder in a new memo. Reminders are kept only on this device and aren’t written to your files. Reminders for completed to-dos don’t go off.")
                }

                Section {
                    LabeledContent("To-do Keywords", value: "TODO | DONE")
                    NavigationLink("Backups") { BackupList() }
                } footer: {
                    Text("If a file has a #+TODO: line, its keywords are used. Backups hold the versions you didn’t keep when a conflict occurred.")
                }
            }
            .task {
                notificationsBlocked = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
            }
            .alert("Calendar Access Not Allowed", isPresented: $calendarDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow access in Settings › Apps › Orgnote.")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(url): store.choose(folder: url)
                case let .failure(error):
                    store.notice = Notice(message: String(localized: "Couldn’t open the folder. (\(error.localizedDescription))"), isError: true)
                }
            }
        }
    }
}

/// Which calendars feed the agenda, grouped by account like the Calendar app.
private struct CalendarChoice: View {
    @Environment(CalendarEvents.self) private var events

    var body: some View {
        let groups = Dictionary(grouping: events.calendars) { $0.source.title }
        List {
            ForEach(groups.keys.sorted(), id: \.self) { account in
                Section(account) {
                    ForEach(groups[account] ?? [], id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding {
                            !events.hidden.contains(calendar.calendarIdentifier)
                        } set: { on in
                            events.setHidden(calendar, !on)
                        }) {
                            Label {
                                Text(calendar.title)
                            } icon: {
                                Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 12, height: 12)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Calendars to Show")
        .overlay {
            if events.calendars.isEmpty {
                ContentUnavailableView("No Calendars", systemImage: "calendar",
                                       description: Text("Turn on the calendars for your Google account in Settings."))
            }
        }
    }
}

private struct BackupList: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let backups = store.backups()
        List(backups, id: \.self) { url in
            ShareLink(item: url) {
                Label(url.lastPathComponent, systemImage: "doc.text")
                    .lineLimit(2)
            }
        }
        .navigationTitle("Backups")
        .overlay {
            if backups.isEmpty {
                ContentUnavailableView("No Backups", systemImage: "clock.arrow.circlepath",
                                       description: Text("When edits on another device conflict, the version you didn’t keep is saved here."))
            }
        }
    }
}
