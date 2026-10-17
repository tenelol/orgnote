import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("captureAsTodo") private var asTodo = false
    @State private var picking = false

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
                    LabeledContent("TODOキーワード", value: "TODO | DONE")
                    NavigationLink("バックアップ") { BackupList() }
                } footer: {
                    Text("ファイルに #+TODO: 行があれば、そのキーワードを使います。バックアップには、競合したときに残さなかった版が入ります。")
                }
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
