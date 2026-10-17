import OrgKit
import SwiftUI

/// One folder of the library, like a folder in Notes or Files. The root shows
/// the top level; folders push another LibraryView.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    var folder = ""
    @State private var showSettings = false
    @State private var naming: NewItem?
    @State private var newName = ""
    @State private var createdFile: String?

    private enum NewItem: String, Identifiable {
        case file, folder
        var id: String { rawValue }
    }

    private var isRoot: Bool { folder.isEmpty }
    private var locationName: String { isRoot ? store.folderName : (folder as NSString).lastPathComponent }

    var body: some View {
        let contents = store.contents(of: folder)
        List {
            if !contents.folders.isEmpty {
                Section {
                    ForEach(contents.folders, id: \.self) { path in
                        NavigationLink(value: Route.folder(path)) {
                            Label {
                                Text((path as NSString).lastPathComponent)
                            } icon: {
                                Image(systemName: "folder").foregroundStyle(.tint)
                            }
                        }
                        .badge(store.fileCount(under: path))
                    }
                }
            }
            if !contents.files.isEmpty {
                Section {
                    ForEach(contents.files) { file in
                        NavigationLink(value: Route.file(file.id, line: nil)) {
                            FileRow(file: file, isCaptureTarget: file.id == store.inboxPath)
                        }
                        .disabled(file.isPlaceholder)
                        .contextMenu {
                            ShareLink(item: file.url) { Label("共有…", systemImage: "square.and.arrow.up") }
                            if file.id != store.inboxPath {
                                Button("新規メモの保存先にする", systemImage: "tray.and.arrow.down") { store.inboxPath = file.id }
                            }
                        }
                    }
                }
            }
            if isRoot, !store.errors.isEmpty {
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
        .listStyle(.insetGrouped)
        .navigationTitle(isRoot ? "メモ" : locationName)
        .navigationSubtitle(isRoot ? store.folderName : "")
        .refreshable { await store.refresh() }
        .overlay {
            if contents.files.isEmpty, contents.folders.isEmpty, !store.isRefreshing {
                if isRoot {
                    ContentUnavailableView {
                        Label("メモがありません", systemImage: "square.and.pencil")
                    } description: {
                        Text("書いたメモは \(store.inboxPath) に追記されます。")
                    } actions: {
                        Button("新規メモ") { router.showCapture = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("空のフォルダ", systemImage: "folder",
                                           description: Text("右上のメニューからファイルを作成できます。"))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新規ファイル…", systemImage: "doc.badge.plus") { ask(.file) }
                    Button("新規フォルダ…", systemImage: "folder.badge.plus") { ask(.folder) }
                    if isRoot {
                        Divider()
                        Button("設定", systemImage: "gearshape") { showSettings = true }
                    }
                } label: {
                    Label("その他", systemImage: "ellipsis")
                }
            }
        }
        .alert(naming == .folder ? "新規フォルダ" : "新規ファイル",
               isPresented: Binding { naming != nil } set: { if !$0 { naming = nil } },
               presenting: naming) { item in
            TextField(item == .folder ? "フォルダ名" : "ファイル名", text: $newName)
            Button("作成") {
                Task {
                    switch item {
                    case .file: createdFile = await store.createFile(named: newName, in: folder)
                    case .folder: _ = await store.createFolder(named: newName, in: folder)
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) {}
        } message: { item in
            Text(item == .folder ? "「\(locationName)」にフォルダを作成します。" : "「\(locationName)」に .org ファイルを作成します。")
        }
        .navigationDestination(item: $createdFile) { id in
            DocumentView(fileID: id, focusLine: nil)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func ask(_ item: NewItem) {
        newName = ""
        naming = item
    }
}

struct FileRow: View {
    var file: OrgFile
    var isCaptureTarget = false
    /// Folder rows already show where a file lives; flat lists such as search need the path.
    var showsFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(file.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if isCaptureTarget {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("新規メモの保存先")
                }
            }
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
            if showsFolder, let folder = file.folder {
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
