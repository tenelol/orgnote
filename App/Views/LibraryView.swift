import OrgKit
import SwiftUI

/// The notebook shelf: each .org file is a notebook with a cover, folders
/// group them, and two tiles up top lead to today's agenda and the inbox.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(NotebookStyles.self) private var styles
    var folder = ""
    @State private var showSettings = false
    @State private var naming: NewItem?
    @State private var newName = ""
    @State private var createdFile: String?
    @State private var editingCover: CoverTarget?
    @State private var deleting: OrgFile?

    private struct CoverTarget: Identifiable {
        var id: String
    }

    private enum NewItem: String, Identifiable {
        case file, folder
        var id: String { rawValue }
    }

    private var isRoot: Bool { folder.isEmpty }
    private var locationName: String { isRoot ? store.folderName : (folder as NSString).lastPathComponent }

    var body: some View {
        let contents = store.contents(of: folder)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isRoot { smartTiles }
                if !contents.folders.isEmpty { folderList(contents.folders) }
                if !contents.files.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(contents.files) { file in
                            NavigationLink(value: Route.notebook(file.id)) {
                                NotebookCover(file: file, isCaptureTarget: file.id == store.inboxPath)
                            }
                            .buttonStyle(.plain)
                            .disabled(file.isPlaceholder)
                            .contextMenu { coverMenu(file) }
                        }
                    }
                }
                if isRoot, !store.errors.isEmpty { unreadable }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isRoot ? "メモ" : locationName)
        .navigationSubtitle(isRoot ? store.folderName : "")
        .overlay {
            if contents.files.isEmpty, contents.folders.isEmpty, !store.isRefreshing {
                if isRoot {
                    ContentUnavailableView {
                        Label("ノートがありません", systemImage: "books.vertical")
                    } description: {
                        Text("書いたメモは \(store.inboxPath) に追記されます。")
                    } actions: {
                        Button("新規メモ") { router.showCapture = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("空のフォルダ", systemImage: "folder",
                                           description: Text("右上のメニューからノートを作成できます。"))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新規ノート…", systemImage: "book.closed") { ask(.file) }
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
        .alert(naming == .folder ? "新規フォルダ" : "新規ノート",
               isPresented: Binding { naming != nil } set: { if !$0 { naming = nil } },
               presenting: naming) { item in
            TextField(item == .folder ? "フォルダ名" : "ノート名", text: $newName)
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
            NotebookView(fileID: id)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $editingCover) { target in CoverEditor(fileID: target.id) }
        .confirmationDialog(
            deleting.map { "「\($0.displayName)」を削除しますか？" } ?? "",
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            titleVisibility: .visible,
            presenting: deleting
        ) { file in
            Button("ノートを削除", role: .destructive) {
                Task {
                    let deleted = await store.deleteFile(file.id)
                    UINotificationFeedbackGenerator().notificationOccurred(deleted ? .success : .error)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { file in
            let count = file.document.headlines.count
            Text((count > 0 ? "中の見出し\(count)件も一緒に消えます。" : "")
                + "削除前の内容は「設定 › バックアップ」に残ります。")
        }
    }

    private var smartTiles: some View {
        let agenda = store.agenda()
        let today = agenda.overdue.count + (agenda.days.first?.items.filter { !$0.headline.isDone }.count ?? 0)
        let unsorted = store.inbox?.document.headlines.filter { $0.level == 1 && !$0.isDone }.count ?? 0
        return HStack(spacing: 12) {
            Button { router.requestedTab = .agenda } label: {
                SmartTile(symbol: "calendar", tint: .red, count: today, title: "今日")
            }
            Button { router.showTriage = true } label: {
                SmartTile(symbol: "tray", tint: .accentColor, count: unsorted, title: "未整理")
            }
        }
        .buttonStyle(.plain)
    }

    private func folderList(_ folders: [String]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(folders.enumerated()), id: \.element) { index, path in
                NavigationLink(value: Route.folder(path)) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint).accessibilityHidden(true)
                        Text((path as NSString).lastPathComponent).foregroundStyle(.primary)
                        Spacer()
                        Text("\(store.fileCount(under: path))").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < folders.count - 1 { Divider().padding(.leading, 48) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func coverMenu(_ file: OrgFile) -> some View {
        Button("表紙を編集…", systemImage: "paintpalette") { editingCover = CoverTarget(id: file.id) }
        if file.id != store.inboxPath {
            Button("新規メモの保存先にする", systemImage: "tray.and.arrow.down") { store.inboxPath = file.id }
        }
        Button("全体をテキストで開く", systemImage: "doc.plaintext") {
            router.paths[.notes, default: []].append(.file(file.id, line: nil))
        }
        ShareLink(item: file.url) { Label("共有…", systemImage: "square.and.arrow.up") }
        // The capture target stays: new memos would just recreate it.
        if file.id != store.inboxPath {
            Divider()
            Button("ノートを削除…", systemImage: "trash", role: .destructive) { deleting = file }
        }
    }

    private var unreadable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("読めないファイル").font(.headline)
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

    private func ask(_ item: NewItem) {
        newName = ""
        naming = item
    }
}

/// A Reminders-style count tile.
private struct SmartTile: View {
    var symbol: String
    var tint: Color
    var count: Int
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint, in: Circle())
                    .accessibilityHidden(true)
                Spacer()
                Text("\(count)")
                    .font(.title.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(count)件")
    }
}

/// A notebook cover: tinted page, colored spine, and what's inside at a glance.
struct NotebookCover: View {
    @Environment(NotebookStyles.self) private var styles
    var file: OrgFile
    var isCaptureTarget: Bool
    /// Shows an unsaved cover while it is being edited.
    var override: NotebookStyle?

    var body: some View {
        let style = override ?? styles.style(for: file.id, isCaptureTarget: isCaptureTarget)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: style.symbol)
                    .font(.title2)
                    .foregroundStyle(style.tint)
                    .accessibilityHidden(true)
                Spacer()
                if isCaptureTarget {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("新規メモの保存先")
                }
            }
            Spacer(minLength: 8)
            Text(file.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 20)
        .padding([.vertical, .trailing], 14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(alignment: .leading) {
                    Rectangle().fill(style.tint).frame(width: 7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(style.tint.opacity(0.08))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        if file.isPlaceholder { return "iCloudからダウンロード中" }
        let headlines = file.document.headlines
        let tasks = headlines.filter { $0.keyword != nil }
        let open = tasks.filter { !$0.isDone }
        let today = OrgDate(.now)
        if let next = open.compactMap({ $0.deadline?.date ?? $0.scheduled?.date }).min() {
            return next < today ? "期限切れあり · TODO \(open.count)" : "\(DateLabel.short(next)) · TODO \(open.count)"
        }
        if !tasks.isEmpty { return "TODO \(tasks.count - open.count)/\(tasks.count) 完了" }
        let notes = headlines.filter { $0.level <= 2 }.count
        return notes == 0 ? "空のノート" : "メモ \(notes)件"
    }
}

/// Picks a notebook's color and symbol.
struct CoverEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(NotebookStyles.self) private var styles
    @Environment(\.dismiss) private var dismiss
    var fileID: String
    @State private var style = NotebookStyle(color: "green", symbol: "book.closed")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let file = store.files[fileID] {
                        NotebookCover(file: file, isCaptureTarget: false, override: style)
                            .frame(maxWidth: 200)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
                Section("色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(NotebookStyle.colors, id: \.name) { entry in
                            Button {
                                style.color = entry.name
                            } label: {
                                Circle()
                                    .fill(entry.color)
                                    .frame(width: 32, height: 32)
                                    .overlay { if style.color == entry.name { Circle().strokeBorder(.white, lineWidth: 3) } }
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.name)
                            .accessibilityAddTraits(style.color == entry.name ? .isSelected : [])
                        }
                    }
                }
                Section("アイコン") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(NotebookStyle.symbols, id: \.self) { symbol in
                            Button {
                                style.symbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(style.symbol == symbol ? .white : style.tint)
                                    .background(style.symbol == symbol ? style.tint : Color(.tertiarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(style.symbol == symbol ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("表紙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark", role: .confirm) {
                        styles.set(style, for: fileID)
                        dismiss()
                    }
                }
            }
            .onAppear { style = styles.style(for: fileID, isCaptureTarget: fileID == store.inboxPath) }
        }
        .presentationDetents([.large])
    }
}
