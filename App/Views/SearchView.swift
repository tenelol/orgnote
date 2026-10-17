import OrgKit
import SwiftUI

/// Search with a tag cloud and recent entries before typing, tag tokens for
/// narrowing, and results that show where each match lives.
struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(NotebookStyles.self) private var styles
    @Environment(RecentEntries.self) private var recents
    @State private var query = ""
    @State private var tokens: [TagToken] = []

    struct TagToken: Identifiable, Hashable {
        var tag: String
        var id: String { tag }
    }

    struct Result: Identifiable {
        var fileID: String
        var headline: OrgHeadline
        /// The matching body line, when the match is not in the title.
        var snippet: String?
        var id: String { "\(fileID)#\(headline.identity)" }
    }

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        List {
            if trimmed.isEmpty, tokens.isEmpty {
                browse
            } else {
                let results = results(for: trimmed)
                let places = places(matching: trimmed)
                if !places.files.isEmpty || !places.folders.isEmpty {
                    Section {
                        ForEach(places.folders, id: \.self) { path in
                            NavigationLink(value: Route.folder(path)) {
                                PlaceRow(title: (path as NSString).lastPathComponent,
                                         place: (path as NSString).deletingLastPathComponent,
                                         symbol: "folder.fill", tint: .accentColor, query: trimmed)
                            }
                        }
                        ForEach(places.files) { file in
                            let style = styles.style(for: file.id, isCaptureTarget: file.id == store.inboxPath)
                            NavigationLink(value: Route.notebook(file.id)) {
                                PlaceRow(title: file.displayName, place: file.id,
                                         symbol: style.symbol, tint: style.tint, query: trimmed)
                            }
                        }
                    } header: {
                        Text("ノート").textCase(nil)
                    }
                }
                if results.isEmpty, places.files.isEmpty, places.folders.isEmpty {
                    // A row, not an overlay: an empty section has nothing to overlay.
                    ContentUnavailableView.search(text: trimmed.isEmpty ? tokens.map { "#\($0.tag)" }.joined(separator: " ") : trimmed)
                        .listRowBackground(Color.clear)
                } else if !results.isEmpty {
                    Section {
                        ForEach(results) { result in
                            NavigationLink(value: Route.entry(result.fileID, line: result.headline.lineIndex)) {
                                ResultRow(result: result, query: trimmed, place: place(of: result),
                                          tint: tint(for: result.fileID))
                            }
                        }
                    } header: {
                        Text("結果 \(results.count)件").textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("検索")
        .searchable(text: $query, tokens: $tokens, prompt: "ノート名・見出し・本文・#タグ") { token in
            Label(token.tag, systemImage: "number")
        }
        .onChange(of: query) { _, text in
            // Typing "#tag " turns into a token, like Notes.
            guard text.hasSuffix(" "), let word = text.split(separator: " ").last, word.hasPrefix("#"), word.count > 1 else { return }
            let tag = String(word.dropFirst())
            if !tokens.contains(TagToken(tag: tag)) { tokens.append(TagToken(tag: tag)) }
            query = String(text.dropLast(word.count + 1))
        }
    }

    // MARK: Before typing

    @ViewBuilder private var browse: some View {
        let tags = tagCounts
        if !tags.isEmpty {
            Section("タグ") {
                FlowLayout(spacing: 10) {
                    ForEach(tags, id: \.tag) { entry in
                        Button {
                            withAnimation(.snappy) { tokens = [TagToken(tag: entry.tag)] }
                        } label: {
                            Text("#\(entry.tag)")
                                .font(cloudFont(entry.count, max: tags.first?.count ?? 1))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("タグ \(entry.tag)、\(entry.count)件")
                    }
                }
                .padding(.vertical, 6)
            }
        }
        let recent = recents.items.compactMap(resolve)
        if !recent.isEmpty {
            Section {
                ForEach(recent) { result in
                    NavigationLink(value: Route.entry(result.fileID, line: result.headline.lineIndex)) {
                        ResultRow(result: result, query: "", place: place(of: result), tint: tint(for: result.fileID))
                    }
                }
            } header: {
                HStack {
                    Text("最近開いたメモ")
                    Spacer()
                    Button("消去") { withAnimation { recents.clear() } }
                        .font(.footnote)
                }
                .textCase(nil)
            }
        }
        if tags.isEmpty, recent.isEmpty {
            ContentUnavailableView("メモを探す", systemImage: "magnifyingglass",
                                   description: Text("ノート名、見出しや本文の言葉、#タグで探せます。"))
                .listRowBackground(Color.clear)
        }
    }

    /// Bigger type for tags used more, in three steps.
    private func cloudFont(_ count: Int, max: Int) -> Font {
        let ratio = Double(count) / Double(Swift.max(max, 1))
        if ratio > 0.66 { return .title2.weight(.semibold) }
        if ratio > 0.33 { return .title3.weight(.medium) }
        return .body
    }

    private var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for file in store.files.values {
            for headline in file.document.headlines { for tag in headline.tags { counts[tag, default: 0] += 1 } }
        }
        let sorted = counts.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
        return sorted.prefix(30).map { (tag: $0.key, count: $0.value) }
    }

    // MARK: Results

    private func results(for query: String) -> [Result] {
        var seen: Set<String> = []
        var results: [Result] = []
        for file in store.sortedFiles where !file.isPlaceholder {
            let document = file.document
            for headline in document.headlines {
                guard tokens.allSatisfy({ headline.tags.contains($0.tag) }) else { continue }
                var snippet: String?
                if !query.isEmpty {
                    if !headline.displayTitle.localizedStandardContains(query) {
                        guard let line = document.bodyLines(of: headline).first(where: { $0.localizedStandardContains(query) })
                        else { continue }
                        snippet = line.trimmingCharacters(in: .whitespaces)
                    }
                }
                let result = Result(fileID: file.id, headline: headline, snippet: snippet)
                if seen.insert(result.id).inserted { results.append(result) }
                if results.count >= 200 { return results }
            }
        }
        return results
    }

    /// Notebooks and folders whose name or path matches; tag tokens search entries only.
    private func places(matching query: String) -> (files: [OrgFile], folders: [String]) {
        guard !query.isEmpty, tokens.isEmpty else { return ([], []) }
        let files = store.sortedFiles.filter { file in
            file.displayName.localizedStandardContains(query) || file.id.localizedStandardContains(query)
        }
        let folders = store.folders.sorted().filter { ($0 as NSString).lastPathComponent.localizedStandardContains(query) }
        return (files, folders)
    }

    /// A recent entry, found again by title since its line may have moved.
    private func resolve(_ recent: RecentEntries.Item) -> Result? {
        guard let document = store.files[recent.fileID]?.document else { return nil }
        let headline = document.headline(at: recent.line).flatMap { $0.title == recent.title ? $0 : nil }
            ?? document.headlines.first { $0.title == recent.title }
        return headline.map { Result(fileID: recent.fileID, headline: $0, snippet: nil) }
    }

    private func place(of result: Result) -> String {
        guard let file = store.files[result.fileID] else { return result.fileID }
        let parent = file.document.headlines.last {
            $0.lineIndex < result.headline.lineIndex && $0.subtreeEndLineIndex > result.headline.lineIndex
        }
        return [file.displayName, parent?.displayTitle].compactMap { $0 }.joined(separator: " › ")
    }

    private func tint(for fileID: String) -> Color {
        styles.style(for: fileID, isCaptureTarget: fileID == store.inboxPath).tint
    }
}

/// A notebook or folder hit, styled like its cover on the shelf.
private struct PlaceRow: View {
    var title: String
    var place: String
    var symbol: String
    var tint: Color
    var query: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ResultRow.highlighted(title, query: query)).font(.headline).lineLimit(1)
                if !place.isEmpty {
                    Text(ResultRow.highlighted(place, query: query)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// A hit with its location and the matching words highlighted.
private struct ResultRow: View {
    var result: SearchView.Result
    var query: String
    var place: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                if result.headline.keyword != nil {
                    Image(systemName: result.headline.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(result.headline.isDone ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(result.headline.isDone ? "完了" : "未完了")
                }
                Text(highlighted(result.headline.displayTitle.isEmpty ? "無題" : result.headline.displayTitle))
                    .font(.headline)
                    .lineLimit(2)
            }
            if let snippet = result.snippet {
                Text(highlighted(snippet)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if !result.headline.tags.isEmpty {
                Text(result.headline.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    private func highlighted(_ text: String) -> AttributedString { Self.highlighted(text, query: query) }

    /// Marks every match like a highlighter pen.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: searchRange) {
            if let lower = AttributedString.Index(match.lowerBound, within: attributed),
               let upper = AttributedString.Index(match.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            searchRange = match.upperBound..<text.endIndex
        }
        return attributed
    }
}

/// Entries opened lately, kept on this device for the search screen.
@MainActor @Observable
final class RecentEntries {
    static let shared = RecentEntries()
    private static let key = "recentEntries"

    struct Item: Codable, Hashable {
        var fileID: String
        var line: Int
        var title: String
    }

    private(set) var items: [Item]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        items = data.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    func record(fileID: String, line: Int, title: String) {
        items.removeAll { $0.fileID == fileID && $0.title == title }
        items.insert(Item(fileID: fileID, line: line, title: title), at: 0)
        items = Array(items.prefix(8))
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }
}
