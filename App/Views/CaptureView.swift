import OrgKit
import SwiftUI

/// The quick-capture sheet. It uses the same live-preview editor and keyboard
/// bar as notes; the first line becomes the heading and the rest its body,
/// like the title line of a note in Notes.
struct CaptureView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// The default from Settings; this sheet only reads it.
    @AppStorage("captureAsTodo") private var defaultTodo = false
    @State private var text = ""
    @State private var target: String?
    /// A day being picked from the keyboard bar, shown inline: a second sheet
    /// on top of this one would break HIG.
    @State private var picking: (kind: PlanningKind, line: Int)?
    @State private var pickedDate = Date.now
    @State private var confirmingDiscard = false
    @State private var controller = EditorController()

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isTask: Bool { OrgDocument(text: text).headline(at: 0)?.keyword != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                OrgTextView(
                    text: text,
                    onChange: { text = $0 },
                    onToggle: { toggle in
                        var document = OrgDocument(text: text)
                        OrgCommands.toggle(toggle, in: &document)
                        text = document.text
                    },
                    capture: .init(placeholder: "1行目が見出しになります"),
                    controller: controller
                )
                if let picking {
                    inlineDatePicker(kind: picking.kind, line: picking.line)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                } else {
                    destination
                }
            }
            .animation(.snappy, value: picking?.line)
            .navigationTitle(isTask ? "新規TODO" : "新規メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark", role: .cancel) {
                        if isEmpty { dismiss() } else { confirmingDiscard = true }
                    }
                    .confirmationDialog("このメモを破棄しますか？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("メモを破棄", role: .destructive) { dismiss() }
                        Button("編集を続ける", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加", systemImage: "checkmark", role: .confirm) { submit() }
                        .disabled(isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        // Writing needs the full height once the keyboard is up, as in Mail and Messages.
        .presentationDetents([.large])
        .interactiveDismissDisabled(!isEmpty)
        .onAppear {
            controller.onCommand = { command, line in perform(command, line: line) }
            // Starting as a task is just the draft starting as a TODO headline.
            if defaultTodo || router.captureStartsAsTodo { text = "* TODO " }
            router.captureStartsAsTodo = false
            if let requested = router.captureTarget, requested != store.inboxPath { target = requested }
            router.captureTarget = nil
        }
    }

    private var destination: some View {
        Menu {
            Picker("保存先", selection: $target) {
                Text((store.inboxPath as NSString).deletingPathExtension).tag(String?.none)
                ForEach(store.sortedFiles.filter { $0.id != store.inboxPath && !$0.isPlaceholder }) { file in
                    Text(file.displayName).tag(String?.some(file.id))
                }
            }
        } label: {
            Label("保存先: \(target.flatMap { store.files[$0]?.displayName } ?? (store.inboxPath as NSString).deletingPathExtension)",
                  systemImage: "tray.and.arrow.down")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 20)
        }
    }

    private func inlineDatePicker(kind: PlanningKind, line: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            DatePicker(kind == .deadline ? "期限" : "予定日", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
            HStack {
                Button("キャンセル") { picking = nil }
                Spacer()
                Button("完了") {
                    var document = OrgDocument(text: text)
                    OrgCommands.setPlanning(kind, OrgDate(pickedDate), at: line, in: &document)
                    text = document.text
                    picking = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Keyboard-bar commands act on the draft just as they do in the editor.
    /// Commands that need a headline turn the title line into one first, since
    /// it becomes the entry's headline anyway.
    private func perform(_ command: EditorCommand, line: Int) {
        var document = OrgDocument(text: text)
        let needsHeadline: Bool = switch command {
        case .planning, .priority: true
        default: false
        }
        if needsHeadline, document.headline(containing: line) == nil, let first = document.lines.first {
            var lines = document.lines
            lines[0] = "* " + first
            document.replaceText(lines.joined(separator: document.newline))
        }
        switch OrgCommands.apply(command, at: line, to: document) {
        case let .changed(updated):
            text = updated.text
        case let .pickDate(kind, line, current):
            text = document.text
            pickedDate = current
            picking = (kind, line)
        case .none:
            text = document.text
        }
    }

    private func submit() {
        guard !isEmpty else { return }
        let draft = text
        let target = target
        dismiss()
        Task {
            let saved = await store.capture(draft, into: target)
            // Confirm only once the file is written, so the haptic never claims a failed save.
            UINotificationFeedbackGenerator().notificationOccurred(saved == nil ? .error : .success)
        }
    }
}

extension PlanningKind: Identifiable {
    public var id: String { rawValue }
}
