import OrgKit
import SwiftUI

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var showSettings = false
    @State private var naming = false
    @State private var newName = ""
    @State private var createdFile: String?

    var body: some View {
        List { overview }
        .listStyle(.insetGrouped)
        .navigationTitle("メモ")
        .navigationSubtitle(store.folderName)
        .refreshable { await store.refresh() }
        .overlay {
            if store.files.isEmpty, !store.isRefreshing {
                ContentUnavailableView {
                    Label("メモがありません", systemImage: "square.and.pencil")
                } description: {
                    Text("書いたメモはインボックス（\(store.inboxPath)）に入ります。")
                } actions: {
                    Button("新規メモ") { router.showCapture = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新規ファイル…", systemImage: "doc.badge.plus") {
                        newName = ""
                        naming = true
                    }
                    Button("設定", systemImage: "gearshape") { showSettings = true }
                } label: {
                    Label("その他", systemImage: "ellipsis")
                }
            }
        }
        .alert("新規ファイル", isPresented: $naming) {
            TextField("ファイル名", text: $newName)
            Button("作成") {
                Task { createdFile = await store.createFile(named: newName) }
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(store.folderName) に .org ファイルを作成します。")
        }
        .navigationDestination(item: $createdFile) { id in
            DocumentView(fileID: id, focusLine: nil)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    @ViewBuilder private var overview: some View {
        Section {
            // Opens even before the first capture; DocumentView creates the empty inbox.
            NavigationLink(value: Route.file(store.inboxPath, line: nil)) {
                Label {
                    Text("インボックス")
                } icon: {
                    Image(systemName: "tray").foregroundStyle(.tint)
                }
            }
            .badge(store.inbox?.document.headlines.count ?? 0)
        }

        let others = store.sortedFiles.filter { $0.id != store.inboxPath }
        if !others.isEmpty {
            Section("ファイル") {
                ForEach(others) { file in
                    NavigationLink(value: Route.file(file.id, line: nil)) {
                        FileRow(file: file)
                    }
                    .disabled(file.isPlaceholder)
                    .contextMenu {
                        ShareLink(item: file.url) { Label("共有…", systemImage: "square.and.arrow.up") }
                        Button("インボックスにする", systemImage: "tray") { store.inboxPath = file.id }
                    }
                }
            }
        }

        if !store.errors.isEmpty {
            Section("読めないファイル") {
                ForEach(store.errors.sorted(by: { $0.key < $1.key }), id: \.key) { id, message in
                    Label {
                        VStack(alignment: .leading) {
                            Text(id)
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

struct FileRow: View {
    var file: OrgFile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.displayName)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                if file.isPlaceholder {
                    ProgressView().controlSize(.mini)
                    Text("iCloudからダウンロード中")
                } else {
                    if let modified = file.modified {
                        Text(modified, format: .relativeDate)
                    }
                    Text(file.preview).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.subheadline)
            if let folder = file.folder {
                HStack(spacing: 4) {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(folder)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SearchResults: View {
    @Environment(LibraryStore.self) private var store
    var query: String

    var body: some View {
        let hits = store.search(query)
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            let grouped = Dictionary(grouping: hits, by: \.fileID)
            ForEach(store.sortedFiles.filter { grouped[$0.id] != nil }) { file in
                Section(file.displayName) {
                    ForEach(grouped[file.id]!) { hit in
                        NavigationLink(value: Route.file(hit.fileID, line: hit.line)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.text).lineLimit(2)
                                if let context = hit.context {
                                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension FormatStyle where Self == Date.RelativeFormatStyle {
    static var relativeDate: Date.RelativeFormatStyle { .relative(presentation: .named, unitsStyle: .abbreviated) }
}
