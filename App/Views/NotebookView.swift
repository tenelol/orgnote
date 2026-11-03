import OrgKit
import SwiftUI

/// Inside a notebook: top-level headings with children become sections, and
/// each entry is a card. Tapping a card opens just that entry.
struct NotebookView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(NotebookStyles.self) private var styles
    var fileID: String
    @State private var moving: MoveRequest?
    @State private var undo: DeletedEntry?

    var body: some View {
        if let file = store.files[fileID] {
            let style = styles.style(for: fileID, isCaptureTarget: fileID == store.inboxPath)
            let groups = NotebookGroup.groups(in: file.document)
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries, id: \.identity) { entry in
                            card(entry, in: file.document)
                        }
                    } header: {
                        if let title = group.title, let line = group.lineIndex {
                            NavigationLink(value: Route.entry(fileID, line: line)) {
                                HStack(spacing: 6) {
                                    Text(title).font(.title3.weight(.bold)).foregroundStyle(style.tint)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .tint(style.tint)
            .navigationTitle(file.displayName)
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label("No Memos", systemImage: style.symbol)
                    } description: {
                        Text("Memos you write in this notebook appear here.")
                    } actions: {
                        Button("New Memo") { newMemo() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .toolbar {
                if fileID == store.inboxPath, !groups.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Sort Memos", systemImage: "rectangle.stack") { router.showTriage = true }
                            .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.file(fileID, line: nil)) {
                        Label("Open as Plain Text", systemImage: "doc.plaintext")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Memo", systemImage: "square.and.pencil", action: newMemo)
                }
            }
            .sheet(item: $moving) { request in
                MoveSheet(request: request)
            }
            .safeAreaInset(edge: .bottom) {
                UndoBanner(deleted: $undo) { deleted in
                    store.restoreEntry(deleted.lines, in: fileID, at: deleted.line)
                }
            }
        } else {
            ContentUnavailableView("Notebook Not Found", systemImage: "book.closed",
                                   description: Text("\(fileID) may have been moved or deleted."))
        }
    }

    private func card(_ entry: OrgHeadline, in document: OrgDocument) -> some View {
        NavigationLink(value: Route.entry(fileID, line: entry.lineIndex)) {
            MemoCard(headline: entry, document: document) {
                store.edit(fileID) { $0.toggleDone(forHeadlineAt: entry.lineIndex) }
            }
        }
        .swipeActions(edge: .trailing) {
            // Destructive stays red even though the list is tinted with the notebook color.
            Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
                .tint(.red)
            Button("Move", systemImage: "folder") { moving = MoveRequest(fileID: fileID, line: entry.lineIndex) }
                .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            if entry.keyword != nil {
                Button(entry.isDone ? "Mark as Not Done" : "Mark as Done",
                       systemImage: entry.isDone ? "arrow.uturn.backward" : "checkmark") {
                    store.edit(fileID) { $0.toggleDone(forHeadlineAt: entry.lineIndex) }
                }
                .tint(.accentColor)
            }
        }
        .contextMenu {
            Button("Move…", systemImage: "folder") { moving = MoveRequest(fileID: fileID, line: entry.lineIndex) }
            Button(entry.keyword == nil ? "Make To-do" : "Unmark To-do", systemImage: "checkmark.circle") {
                store.edit(fileID) { $0.setKeyword(entry.keyword == nil ? $0.keywords.active.first : nil,
                                                   forHeadlineAt: entry.lineIndex) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
        }
    }

    /// Deletes at once, as Notes and Mail do, with an undo instead of a confirmation.
    private func delete(_ entry: OrgHeadline) {
        guard let lines = store.deleteEntry(fileID, line: entry.lineIndex) else { return }
        withAnimation(.snappy) {
            undo = DeletedEntry(lines: lines, line: entry.lineIndex, title: entry.displayTitle)
        }
    }

    private func newMemo() {
        router.captureTarget = fileID
        router.showCapture = true
    }
}

/// A run of cards, optionally under a top-level heading.
struct NotebookGroup: Identifiable {
    var title: String?
    var lineIndex: Int?
    var entries: [OrgHeadline]
    var id: String { title.map { "section:\($0)#\(lineIndex ?? 0)" } ?? "run:\(entries.first?.identity ?? "")" }

    /// Top-level headings that have children become sections of their direct
    /// children; childless top-level headings are cards in untitled runs.
    static func groups(in document: OrgDocument) -> [NotebookGroup] {
        var groups: [NotebookGroup] = []
        let headlines = document.headlines
        for top in headlines where top.level == 1 {
            let children = headlines.filter {
                $0.level == 2 && $0.lineIndex > top.lineIndex && $0.lineIndex < top.subtreeEndLineIndex
            }
            if children.isEmpty {
                if let last = groups.last, last.title == nil {
                    groups[groups.count - 1].entries.append(top)
                } else {
                    groups.append(NotebookGroup(title: nil, lineIndex: nil, entries: [top]))
                }
            } else {
                groups.append(NotebookGroup(title: top.displayTitle, lineIndex: top.lineIndex, entries: children))
            }
        }
        return groups
    }
}

/// One entry as a card: title, a line of its text, and what it carries.
struct MemoCard: View {
    var headline: OrgHeadline
    var document: OrgDocument
    var onToggle: () -> Void
    @State private var taps = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if headline.keyword != nil {
                Button {
                    taps += 1
                    onToggle()
                } label: {
                    Image(systemName: headline.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(headline.isDone ? Color.accentColor : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: taps)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.leading, -8)
                .padding(.vertical, -8)
                .accessibilityLabel(headline.isDone ? "Mark as Not Done" : "Mark as Done")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let priority = headline.priority {
                        Text(PriorityLabel.marks(priority)).font(.headline).foregroundStyle(.red)
                            .accessibilityLabel("\(PriorityLabel.spoken(priority)) priority")
                    }
                    Text(headline.displayTitle.isEmpty ? String(localized: "Untitled") : headline.displayTitle)
                        .font(.headline)
                        .strikethrough(headline.isDone, color: .secondary)
                        .foregroundStyle(headline.isDone ? .secondary : .primary)
                        .lineLimit(2)
                }
                // A checklist shows as the progress bar below, not as preview text.
                let preview = document.preview(of: headline, includingChecklists: headline.checkboxes.total == 0)
                if !preview.isEmpty {
                    Text(OrgInline.render(preview))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if headline.checkboxes.total > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(headline.checkboxes.done), total: Double(headline.checkboxes.total))
                        Text("\(headline.checkboxes.done)/\(headline.checkboxes.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(headline.checkboxes.done) of \(headline.checkboxes.total) checked")
                }
                let chips = chips
                if !chips.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            HStack(spacing: 3) {
                                Image(systemName: chip.symbol).imageScale(.small).accessibilityHidden(true)
                                Text(chip.text)
                            }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(chip.alert ? Color.red : (chip.accent ? Color.accentColor : Color.secondary))
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private struct Chip: Hashable {
        var symbol: String
        var text: String
        var alert = false
        var accent = false
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        let today = OrgDate(.now)
        if let deadline = headline.deadline {
            chips.append(Chip(symbol: "flag.fill", text: String(localized: "Due \(DateLabel.short(deadline.date))"),
                              alert: !headline.isDone && deadline.date <= today))
        }
        if let scheduled = headline.scheduled {
            chips.append(Chip(symbol: "calendar", text: DateLabel.short(scheduled.date),
                              alert: !headline.isDone && scheduled.date < today, accent: true))
        }
        let children = document.headlines.filter {
            $0.lineIndex > headline.lineIndex && $0.lineIndex < headline.subtreeEndLineIndex
        }.count
        if children > 0 { chips.append(Chip(symbol: "square.stack", text: String(localized: "\(children) items"))) }
        chips += headline.tags.map { Chip(symbol: "number", text: $0, accent: true) }
        if let created = document.created(of: headline) {
            chips.append(Chip(symbol: "clock", text: DateLabel.short(created.date)))
        }
        return chips
    }
}

/// Lays chips out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
