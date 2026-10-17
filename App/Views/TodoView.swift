import OrgKit
import SwiftUI

/// Every task across the folder, like a Reminders list: a summary, quick
/// filters, and sections that carry each notebook's cover color.
struct TodoView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(NotebookStyles.self) private var styles
    @AppStorage("todoGrouping") private var grouping: Grouping = .file
    @AppStorage("todoShowsDone") private var showsDone = false
    @State private var filter: Filter = .all
    /// Finished during this visit; they stay put (struck through) until the
    /// list is left, so completing feels like ticking, not vanishing.
    @State private var justDone: Set<String> = []

    enum Grouping: String, CaseIterable, Identifiable {
        case file, priority, tag
        var id: String { rawValue }
        var title: String {
            switch self {
            case .file: "ノート"
            case .priority: "優先度"
            case .tag: "タグ"
            }
        }
    }

    enum Filter: Hashable {
        case all, dated, urgent
        case tag(String)
    }

    private struct Entry: Identifiable {
        var fileID: String
        var headline: OrgHeadline
        var id: String { "\(fileID)#\(headline.identity)" }
    }

    private struct Group: Identifiable {
        var title: String
        var fileID: String?
        var entries: [Entry]
        var id: String { title }
    }

    var body: some View {
        let all = allTasks
        let groups = makeGroups(all.filter(matches))
        List {
            Section {
                summary(all)
                filters(all)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        row(entry, showsFile: group.fileID == nil)
                    }
                } header: {
                    header(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("TODO")
        .onDisappear { justDone = [] }
        .overlay {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("TODOはありません", systemImage: "checkmark.circle")
                } description: {
                    Text("新規メモで「TODO」を選ぶか、見出しに TODO を付けるとここに集まります。")
                } actions: {
                    Button("新規TODO") {
                        router.captureStartsAsTodo = true
                        router.showCapture = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if groups.isEmpty {
                ContentUnavailableView("該当するTODOはありません", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("絞り込みを「すべて」に戻すと全件が表示されます。"))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("まとめ方", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("完了済みを表示", isOn: $showsDone)
                } label: {
                    Label("表示", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
    }

    // MARK: Parts

    private func summary(_ all: [Entry]) -> some View {
        let open = all.filter { !$0.headline.isDone }
        let weekEnd = OrgDate(.now).adding(days: 6)
        let dueThisWeek = open.filter { ($0.headline.deadline?.date).map { $0 <= weekEnd } ?? false }.count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(open.count)")
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 2) {
                Text("件のこり").font(.headline)
                Text(dueThisWeek > 0 ? "今週が期限 \(dueThisWeek)件" : "今週が期限のものはありません")
                    .font(.subheadline)
                    .foregroundStyle(dueThisWeek > 0 ? Color.red : Color.secondary)
            }
        }
        .animation(.snappy, value: open.count)
        .accessibilityElement(children: .combine)
    }

    private func filters(_ all: [Entry]) -> some View {
        let tags = Dictionary(grouping: all.filter { !$0.headline.isDone }.flatMap(\.headline.tags)) { $0 }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .prefix(6)
            .map(\.key)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("すべて", .all)
                chip("期限・予定あり", .dated, symbol: "calendar")
                chip("優先度 高", .urgent, symbol: "exclamationmark.3")
                ForEach(tags, id: \.self) { chip("#\($0)", .tag($0)) }
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, _ value: Filter, symbol: String? = nil) -> some View {
        let isOn = filter == value
        return Button {
            withAnimation(.snappy) { filter = value }
        } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }

    @ViewBuilder private func header(_ group: Group) -> some View {
        if let fileID = group.fileID {
            let style = styles.style(for: fileID, isCaptureTarget: fileID == store.inboxPath)
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(style.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text(group.title).font(.headline).foregroundStyle(style.tint)
                Spacer()
                Text("\(group.entries.filter { !$0.headline.isDone }.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .textCase(nil)
        } else {
            Text(group.title).font(.headline).textCase(nil)
        }
    }

    private func row(_ entry: Entry, showsFile: Bool) -> some View {
        NavigationLink(value: Route.entry(entry.fileID, line: entry.headline.lineIndex)) {
            HeadlineRow(headline: entry.headline,
                        subtitle: showsFile ? store.files[entry.fileID]?.displayName : nil) {
                withAnimation(.snappy) {
                    if !entry.headline.isDone { justDone.insert(key(entry)) }
                    store.edit(entry.fileID) { $0.toggleDone(forHeadlineAt: entry.headline.lineIndex) }
                }
            }
        }
        .taskActions(fileID: entry.fileID, headline: entry.headline)
        .listRowBackground(
            HStack(spacing: 0) {
                // A red edge marks the top priority, the way Reminders flags urgent items.
                if entry.headline.priority?.uppercased() == "A", !entry.headline.isDone {
                    Rectangle().fill(.red).frame(width: 4)
                }
                Color(.secondarySystemGroupedBackground)
            }
        )
    }

    // MARK: Data

    private func key(_ entry: Entry) -> String {
        "\(entry.fileID)#\(entry.headline.identity)"
    }

    private var allTasks: [Entry] {
        store.sortedFiles.flatMap { file in
            file.document.headlines
                .filter { $0.keyword != nil }
                .map { Entry(fileID: file.id, headline: $0) }
        }
    }

    private func matches(_ entry: Entry) -> Bool {
        let h = entry.headline
        if h.isDone, !showsDone, !justDone.contains(key(entry)) { return false }
        switch filter {
        case .all: return true
        case .dated: return h.scheduled != nil || h.deadline != nil
        case .urgent: return h.priority?.uppercased() == "A"
        case let .tag(tag): return h.tags.contains(tag)
        }
    }

    private func makeGroups(_ entries: [Entry]) -> [Group] {
        let order: (Entry, Entry) -> Bool = {
            let a = ($0.headline.isDone ? 1 : 0, $0.headline.priority ?? "~", $0.headline.deadline?.date ?? OrgDate(year: 9999, month: 1, day: 1))
            let b = ($1.headline.isDone ? 1 : 0, $1.headline.priority ?? "~", $1.headline.deadline?.date ?? OrgDate(year: 9999, month: 1, day: 1))
            return (a.0, a.1) != (b.0, b.1) ? (a.0, a.1) < (b.0, b.1) : a.2 < b.2
        }
        switch grouping {
        case .file:
            return store.sortedFiles.compactMap { file in
                let items = entries.filter { $0.fileID == file.id }
                return items.isEmpty ? nil : Group(title: file.displayName, fileID: file.id, entries: items.sorted(by: order))
            }
        case .priority:
            let groups = Dictionary(grouping: entries) { $0.headline.priority ?? "" }
            return groups.keys.sorted { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }.map { key in
                Group(title: key.isEmpty ? "優先度なし" : "\(PriorityLabel.marks(key))  優先度 \(PriorityLabel.spoken(key))",
                      fileID: nil, entries: groups[key]!.sorted(by: order))
            }
        case .tag:
            var groups: [String: [Entry]] = [:]
            for entry in entries {
                for tag in entry.headline.tags.isEmpty ? [""] : entry.headline.tags {
                    groups[tag, default: []].append(entry)
                }
            }
            return groups.keys.sorted { ($0.isEmpty ? "\u{FFFF}" : $0) < ($1.isEmpty ? "\u{FFFF}" : $1) }.map { key in
                Group(title: key.isEmpty ? "タグなし" : "#\(key)", fileID: nil, entries: groups[key]!.sorted(by: order))
            }
        }
    }
}
