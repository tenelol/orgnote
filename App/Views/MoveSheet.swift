import OrgKit
import SwiftUI

struct MoveRequest: Identifiable, Hashable {
    var fileID: String
    var line: Int
    var id: String { "\(fileID)#\(line)" }
}

/// Picks where an entry goes: a notebook's top level or one of its headings.
/// New notebooks and headings can be made on the spot, so refiling never
/// needs the destination to exist beforehand.
struct MoveSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(NotebookStyles.self) private var styles
    @Environment(\.dismiss) private var dismiss
    var request: MoveRequest
    var onMoved: () -> Void = {}

    @State private var expanded: Set<String> = []
    @State private var naming: Naming?
    @State private var name = ""

    private enum Naming: Identifiable {
        case notebook
        case heading(String)
        var id: String {
            switch self {
            case .notebook: "notebook"
            case let .heading(file): "heading:\(file)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let title = store.files[request.fileID]?.document.headline(at: request.line)?.displayTitle {
                    Section {
                        Label(title, systemImage: "doc.text").foregroundStyle(.secondary)
                    } header: {
                        Text("移動するメモ")
                    }
                }
                Section("移動先") {
                    ForEach(store.sortedFiles.filter { !$0.isPlaceholder }) { file in
                        notebookRow(file)
                    }
                    Button("新しいノート…", systemImage: "plus") { ask(.notebook) }
                }
            }
            .navigationTitle("移動")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .alert(namingTitle, isPresented: Binding { naming != nil } set: { if !$0 { naming = nil } },
                   presenting: naming) { item in
                TextField(item.id == "notebook" ? "ノート名" : "見出し", text: $name)
                Button("作成して移動") { create(item) }
                    .keyboardShortcut(.defaultAction)
                Button("キャンセル", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var namingTitle: String {
        if case .heading = naming { return "新しい見出し" }
        return "新しいノート"
    }

    private func notebookRow(_ file: OrgFile) -> some View {
        let style = styles.style(for: file.id, isCaptureTarget: file.id == store.inboxPath)
        let headings = file.document.headlines.filter {
            $0.level <= 2 && !isMovingEntry(file.id, $0)
        }
        return DisclosureGroup(isExpanded: Binding {
            expanded.contains(file.id)
        } set: { open in
            if open { expanded.insert(file.id) } else { expanded.remove(file.id) }
        }) {
            ForEach(headings) { heading in
                Button {
                    move(to: file.id, under: heading.lineIndex)
                } label: {
                    Label(heading.displayTitle.isEmpty ? "無題" : heading.displayTitle,
                          systemImage: heading.level == 1 ? "number" : "arrow.turn.down.right")
                        .padding(.leading, CGFloat(heading.level - 1) * 16)
                }
                .tint(.primary)
            }
            Button("見出しを追加…", systemImage: "plus") { ask(.heading(file.id)) }
                .font(.subheadline)
        } label: {
            Button {
                move(to: file.id, under: nil)
            } label: {
                Label {
                    Text(file.displayName).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: style.symbol).foregroundStyle(style.tint)
                }
            }
            .tint(.primary)
            .accessibilityHint("ノートの一番上の階層に移動します")
        }
    }

    /// The entry being moved, and anything inside it, cannot be its own destination.
    private func isMovingEntry(_ fileID: String, _ heading: OrgHeadline) -> Bool {
        guard fileID == request.fileID,
              let entry = store.files[fileID]?.document.headline(at: request.line)
        else { return false }
        return heading.lineIndex >= entry.lineIndex && heading.lineIndex < entry.subtreeEndLineIndex
    }

    private func move(to fileID: String, under parent: Int?) {
        if store.moveEntry(from: request.fileID, line: request.line, to: fileID, under: parent) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onMoved()
            dismiss()
        }
    }

    private func ask(_ item: Naming) {
        name = ""
        naming = item
    }

    private func create(_ item: Naming) {
        switch item {
        case .notebook:
            Task {
                guard let id = await store.createFile(named: name) else { return }
                move(to: id, under: nil)
            }
        case let .heading(fileID):
            guard let line = store.addHeading(name, to: fileID) else { return }
            // Adding to the entry's own file shifts nothing above it; headings go at the end.
            move(to: fileID, under: line)
        }
    }
}
