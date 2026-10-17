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
        let base = store.files[fileID].map { offset(in: $0.document) } ?? 0
        switch toggle {
        case let .checkbox(line):
            store.edit(fileID) { $0.toggleCheckbox(at: base + line) }
        case let .todo(line):
            store.edit(fileID) { $0.toggleDone(forHeadlineAt: base + line) }
        case let .link(url):
            openURL(url)
        }
    }

    /// `shownLine` counts from the top of what the editor shows.
    private func perform(_ command: EditorCommand, line shownLine: Int) {
        guard let document = store.files[fileID]?.document else { return }
        let line = offset(in: document) + shownLine
        guard line < document.lines.count else { return }
        let headline = document.headline(containing: line)

        switch command {
        case .heading:
            if document.headline(at: line) != nil {
                controller.insert("*", atLine: shownLine)
            } else {
                let indent = document.lines[line].prefix { $0 == " " || $0 == "\t" }
                // Promote a plain line to a headline; leading indentation would stop Org from seeing it.
                var newLine = document.lines[line]
                newLine.removeFirst(indent.count)
                store.update(fileID, text: replacingLine(line, in: document, with: "* " + newLine))
            }
        case .cycleTodo:
            if let headline {
                store.edit(fileID) { $0.cycleKeyword(forHeadlineAt: headline.lineIndex) }
            } else {
                store.update(fileID, text: replacingLine(line, in: document, with: "* TODO " + document.lines[line]
                    .trimmingCharacters(in: .whitespaces)))
            }
        case .checkbox:
            var copy = document
            if copy.toggleCheckbox(at: line) {
                store.edit(fileID) { $0.toggleCheckbox(at: line) }
            } else {
                let current = document.lines[line]
                let indent = String(current.prefix { $0 == " " || $0 == "\t" })
                var rest = String(current.dropFirst(indent.count))
                if rest.hasPrefix("- ") || rest.hasPrefix("+ ") { rest.removeFirst(2) }
                store.update(fileID, text: replacingLine(line, in: document, with: "\(indent)- [ ] \(rest)"))
            }
        case let .planning(kind, choice):
            guard let headline else { return }
            let today = Date.now
            let calendar = Calendar.current
            switch choice {
            case .today: setPlanning(kind, OrgTimestamp(date: OrgDate(today)), line: headline.lineIndex)
            case .tomorrow: setPlanning(kind, OrgTimestamp(date: OrgDate(today).adding(days: 1)), line: headline.lineIndex)
            case .nextWeek:
                let monday = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? today
                setPlanning(kind, OrgTimestamp(date: OrgDate(monday)), line: headline.lineIndex)
            case .pick:
                let existing = kind == .deadline ? headline.deadline : headline.scheduled
                pickingDate = DatePick(kind: kind, line: headline.lineIndex, date: existing?.date.date() ?? today)
            case .clear: setPlanning(kind, nil, line: headline.lineIndex)
            }
        case let .priority(value):
            guard let headline else { return }
            store.edit(fileID) { $0.setPriority(value, forHeadlineAt: headline.lineIndex) }
        }
    }

    private func setPlanning(_ kind: PlanningKind, _ timestamp: OrgTimestamp?, line: Int) {
        store.edit(fileID) { document in
            // Keep an existing time or repeater when only the day changes.
            var timestamp = timestamp
            if let current = document.headline(at: line)?.planning.first(where: { $0.kind == kind })?.timestamp,
               let new = timestamp {
                var merged = current
                merged.date = new.date
                timestamp = merged
            }
            document.setPlanning(kind, to: timestamp, forHeadlineAt: line)
        }
    }

    private func replacingLine(_ index: Int, in document: OrgDocument, with line: String) -> String {
        var lines = document.lines
        lines[index] = line
        return lines.joined(separator: document.newline)
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
