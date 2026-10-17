import OrgKit
import SwiftUI

/// Every open task across the folder, like a Reminders list per file.
struct TodoView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("todoGrouping") private var grouping: Grouping = .file
    @AppStorage("todoShowsDone") private var showsDone = false

    enum Grouping: String, CaseIterable, Identifiable {
        case file, priority, tag
        var id: String { rawValue }
        var title: String {
            switch self {
            case .file: "ファイル"
            case .priority: "優先度"
            case .tag: "タグ"
            }
        }
    }

    private struct Entry: Identifiable {
        var fileID: String
        var headline: OrgHeadline
        var id: String { "\(fileID)#\(headline.lineIndex)" }
    }

    var body: some View {
        let sections = makeSections()
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        NavigationLink(value: Route.file(entry.fileID, line: entry.headline.lineIndex)) {
                            HeadlineRow(headline: entry.headline,
                                        subtitle: grouping == .file ? nil : store.files[entry.fileID]?.displayName) {
                                withAnimation(.snappy) {
                                    store.edit(entry.fileID) { $0.toggleDone(forHeadlineAt: entry.headline.lineIndex) }
                                }
                            }
                        }
                        .taskActions(fileID: entry.fileID, headline: entry.headline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("TODO")
        .refreshable { await store.refresh() }
        .overlay {
            if sections.isEmpty {
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
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("グループ", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("完了済みを表示", isOn: $showsDone)
                } label: {
                    Label("表示", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
    }

    private func makeSections() -> [(title: String, entries: [Entry])] {
        let entries = store.sortedFiles.flatMap { file in
            file.document.headlines
                .filter { $0.keyword != nil && (showsDone || !$0.isDone) }
                .map { Entry(fileID: file.id, headline: $0) }
        }
        let byPriority: (Entry, Entry) -> Bool = {
            ($0.headline.isDone ? 1 : 0, $0.headline.priority ?? "~") < ($1.headline.isDone ? 1 : 0, $1.headline.priority ?? "~")
        }
        switch grouping {
        case .file:
            return store.sortedFiles.compactMap { file in
                let items = entries.filter { $0.fileID == file.id }
                return items.isEmpty ? nil : (file.displayName, items.sorted(by: byPriority))
            }
        case .priority:
            let groups = Dictionary(grouping: entries) { $0.headline.priority ?? "" }
            return groups.keys.sorted { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }.map { key in
                (key.isEmpty ? "優先度なし" : "\(PriorityLabel.marks(key))  優先度 \(key)", groups[key]!)
            }
        case .tag:
            var groups: [String: [Entry]] = [:]
            for entry in entries {
                for tag in entry.headline.tags.isEmpty ? [""] : entry.headline.tags {
                    groups[tag, default: []].append(entry)
                }
            }
            return groups.keys.sorted { ($0.isEmpty ? "\u{FFFF}" : $0) < ($1.isEmpty ? "\u{FFFF}" : $1) }.map { key in
                (key.isEmpty ? "タグなし" : "#\(key)", groups[key]!.sorted(by: byPriority))
            }
        }
    }
}

struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                Section("最近のファイル") {
                    ForEach(store.sortedFiles.prefix(8)) { file in
                        NavigationLink(value: Route.file(file.id, line: nil)) { FileRow(file: file) }
                    }
                }
            } else {
                SearchResults(query: query)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("検索")
        .searchable(text: $query, prompt: "見出しや本文を検索")
    }
}
