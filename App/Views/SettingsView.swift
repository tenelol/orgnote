import EventKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(CalendarEvents.self) private var events
    @AppStorage("captureAsTodo") private var asTodo = false
    @State private var picking = false
    @State private var denied: String?
    @State private var notificationsBlocked = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    LabeledContent("フォルダ", value: store.folderName)
                    Button("フォルダを変更…") { picking = true }
                } footer: {
                    Text("iCloud Driveのフォルダを選ぶと、Macの ~/org などと同期します。")
                }

                Section("新規メモ") {
                    Picker("保存先", selection: $store.inboxPath) {
                        if store.files[store.inboxPath] == nil {
                            Text(store.inboxPath).tag(store.inboxPath)
                        }
                        ForEach(store.sortedFiles.filter { !$0.isPlaceholder }) { file in
                            Text(file.id).tag(file.id)
                        }
                    }
                    Toggle("最初からTODOにする", isOn: $asTodo)
                }

                Section {
                    Toggle("カレンダーの予定を表示", isOn: Binding {
                        events.isEnabled
                    } set: { on in
                        Task {
                            if await !events.setEnabled(on) { denied = "カレンダー" }
                        }
                    })
                    if events.isEnabled {
                        NavigationLink("表示するカレンダー") { CalendarChoice() }
                    }
                } header: {
                    Text("カレンダー")
                } footer: {
                    Text("iPhoneの設定 › アプリ › カレンダー › カレンダーアカウントにGoogleアカウントを追加すると、Googleカレンダーの予定もアジェンダに並びます。予定は読むだけで変更しません。")
                }

                Section {
                    if notificationsBlocked {
                        Button("通知を許可する…") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    ForEach(TaskNotifications.shared.reminders) { reminder in
                        LabeledContent(reminder.title.isEmpty ? "無題" : reminder.title,
                                       value: reminder.date.formatted(.dateTime.month().day().hour().minute()))
                            .swipeActions {
                                Button("削除", systemImage: "trash", role: .destructive) {
                                    TaskNotifications.shared.remove(reminder)
                                }
                            }
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("新規メモの「通知を追加」で設定します。通知はこのiPhoneだけに保存され、ファイルには書き込みません。完了したTODOの通知は鳴りません。")
                }

                Section {
                    LabeledContent("TODOキーワード", value: "TODO | DONE")
                    NavigationLink("バックアップ") { BackupList() }
                } footer: {
                    Text("ファイルに #+TODO: 行があれば、そのキーワードを使います。バックアップには、競合したときに残さなかった版が入ります。")
                }
            }
            .task {
                notificationsBlocked = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
            }
            .alert("\(denied ?? "")が許可されていません", isPresented: Binding { denied != nil } set: { if !$0 { denied = nil } }) {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("iPhoneの設定 › アプリ › Orgnote で許可すると使えます。")
            }
            .navigationTitle("設定")
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
                    store.notice = Notice(message: "フォルダを開けませんでした。（\(error.localizedDescription)）", isError: true)
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
        .navigationTitle("表示するカレンダー")
        .overlay {
            if events.calendars.isEmpty {
                ContentUnavailableView("カレンダーがありません", systemImage: "calendar",
                                       description: Text("iPhoneの設定でGoogleアカウントのカレンダーをオンにしてください。"))
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
        .navigationTitle("バックアップ")
        .overlay {
            if backups.isEmpty {
                ContentUnavailableView("バックアップはありません", systemImage: "clock.arrow.circlepath",
                                       description: Text("他の端末と同時に編集して競合したとき、残さなかった版がここに保存されます。"))
            }
        }
    }
}
