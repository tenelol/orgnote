import OrgKit
import SwiftUI

struct DocumentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(RecentEntries.self) private var recents
    @Environment(\.openURL) private var openURL
    /// Off shows the raw Org markup everywhere, as Neovim would.
    @AppStorage("livePreview") private var livePreview = true
    var fileID: String
    var focusLine: Int?
    /// Shows only the entry at `focusLine` and its subtree, like Org's narrowing.
    var narrowed = false

    @State private var controller = EditorController()
    @State private var showOutline = false
    @State private var pickingDate: DatePick?
    @State private var didFocus = false
    @State private var isEditing = false
    @State private var narrow: Narrow?

    /// The narrowed window into the file. `known` is the full text after our
    /// own last edit; any other text means the file changed underneath.
    private struct Narrow {
        var start: Int
        var count: Int
        var title: String
        var known: String
    }

    /// Lines of the file the editor shows: everything, or the narrowed entry.
    private func window(in document: OrgDocument) -> Range<Int>? {
        guard narrowed else { return nil }
        guard let narrow else {
            guard let line = focusLine, let lines = document.subtree(at: line) else { return nil }
            return line..<(line + lines.count)
        }
        if document.text == narrow.known, narrow.start + narrow.count <= document.lines.count {
            return narrow.start..<(narrow.start + narrow.count)
        }
        // Changed elsewhere (another device, or a toggle): find the entry again by its title.
        let start = document.headline(at: narrow.start)?.title == narrow.title
            ? narrow.start
            : document.headlines.first { $0.title == narrow.title }?.lineIndex
        guard let start, let lines = document.subtree(at: start) else { return nil }
        return start..<(start + lines.count)
    }

    private func offset(in document: OrgDocument) -> Int { window(in: document)?.lowerBound ?? 0 }

    private func change(_ text: String) {
        guard let document = store.files[fileID]?.document else { return }
        guard let range = window(in: document) else {
            store.update(fileID, text: text)
            return
        }
        var lines = document.lines
        let edited = text.components(separatedBy: document.newline)
        lines.replaceSubrange(range, with: edited)
        let full = lines.joined(separator: document.newline)
        let title = OrgDocument(text: edited.first ?? "").headlines.first?.title ?? narrow?.title ?? ""
        narrow = Narrow(start: range.lowerBound, count: edited.count, title: title, known: full)
        store.update(fileID, text: full)
    }

    private struct DatePick: Identifiable {
        var kind: PlanningKind
        var line: Int
        var date: Date
        var id: Int { line }
    }

    var body: some View {
        if let file = store.files[fileID], !narrowed || window(in: file.document) != nil {
            let document = file.document
            let range = window(in: document)
            let entryTitle = range.flatMap { document.headline(at: $0.lowerBound)?.displayTitle }
            OrgTextView(
                text: range.map { document.lines[$0].joined(separator: document.newline) } ?? document.text,
                onChange: change,
                onToggle: toggle,
                onEditingChanged: { isEditing = $0 },
                livePreview: livePreview,
                controller: controller
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(entryTitle ?? file.displayName)
            .navigationBarTitleDisplayMode(.inline)
            // While typing, the keyboard toolbar takes the bottom edge; the tab bar returns when done.
            .toolbar(isEditing ? .hidden : .automatic, for: .tabBar)
            .animation(.snappy, value: isEditing)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let range {
                        NavigationLink(value: Route.file(fileID, line: range.lowerBound)) {
                            Label("ノート全体", systemImage: "doc.plaintext")
                        }
                    } else {
                        Button("アウトライン", systemImage: "list.bullet.indent") { showOutline = true }
                            .disabled(file.document.headlines.isEmpty)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: Binding { !livePreview } set: { livePreview = !$0 }) {
                            Label("Orgの記法を表示", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        ShareLink(item: file.url) { Label("共有…", systemImage: "square.and.arrow.up") }
                    } label: {
                        Label("その他", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showOutline) {
                OutlineSheet(fileID: fileID) { line in
                    showOutline = false
                    controller.scroll(toLine: line)
                }
            }
            .sheet(item: $pickingDate) { pick in
                DatePickerSheet(title: pick.kind == .deadline ? "期限" : "予定日", date: pick.date) { date in
                    setPlanning(pick.kind, OrgTimestamp(date: OrgDate(date)), line: pick.line)
                }
            }
            .onDisappear { router.openEditors -= 1 }
            .onAppear {
                router.openEditors += 1
                controller.onCommand = { command, line in perform(command, line: line) }
                guard !didFocus else { return }
                didFocus = true
                if narrowed, let range, let title = document.headline(at: range.lowerBound)?.title {
                    narrow = Narrow(start: range.lowerBound, count: range.count, title: title, known: document.text)
                    recents.record(fileID: fileID, line: range.lowerBound, title: title)
                } else if let focusLine {
                    DispatchQueue.main.async { controller.scroll(toLine: focusLine) }
                } else if file.document.text.isEmpty {
                    DispatchQueue.main.async { controller.focus() }
                }
            }
        } else if narrowed, store.files[fileID] != nil {
            ContentUnavailableView("メモが見つかりません", systemImage: "doc.questionmark",
                                   description: Text("移動または削除された可能性があります。"))
        } else {
            ContentUnavailableView("ファイルが見つかりません", systemImage: "doc.questionmark",
                                   description: Text("\(fileID) は移動または削除された可能性があります。"))
        }
    }

    private func toggle(_ toggle: OrgToggle) {
        guard let document = store.files[fileID]?.document else { return }
        let base = offset(in: document)
        switch toggle {
        case let .link(url):
            openURL(url)
        case let .checkbox(line):
            store.edit(fileID) { OrgCommands.toggle(.checkbox(line: base + line), in: &$0) }
        case let .todo(line):
            store.edit(fileID) { OrgCommands.toggle(.todo(line: base + line), in: &$0) }
        }
    }

    /// `shownLine` counts from the top of what the editor shows.
    private func perform(_ command: EditorCommand, line shownLine: Int) {
        guard let document = store.files[fileID]?.document else { return }
        switch OrgCommands.apply(command, at: offset(in: document) + shownLine, to: document) {
        case let .changed(updated):
            store.edit(fileID) { $0.replaceText(updated.text) }
        case let .pickDate(kind, line, current):
            pickingDate = DatePick(kind: kind, line: line, date: current)
        case .none:
            break
        }
    }

    private func setPlanning(_ kind: PlanningKind, _ timestamp: OrgTimestamp?, line: Int) {
        store.edit(fileID) { OrgCommands.setPlanning(kind, timestamp?.date, at: line, in: &$0) }
    }
}

struct DatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    @State var date: Date
    var onPick: (Date) -> Void

    var body: some View {
        NavigationStack {
            DatePicker(title, selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル", systemImage: "xmark", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了", systemImage: "checkmark", role: .confirm) {
                            onPick(date)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
