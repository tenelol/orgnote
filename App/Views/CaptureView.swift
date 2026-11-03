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
    /// When to notify; kept in the app, not written to the file.
    @State private var notifyAt: Date?
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
                    capture: .init(placeholder: String(localized: "The first line becomes the heading")),
                    controller: controller
                )
                if let picking {
                    inlineDatePicker(kind: picking.kind, line: picking.line)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                } else {
                    destination
                    notification
                }
            }
            .animation(.snappy, value: picking?.line)
            .navigationTitle(isTask ? "New To-do" : "New Memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) {
                        if isEmpty { dismiss() } else { confirmingDiscard = true }
                    }
                    .confirmationDialog("Discard This Memo?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Memo", role: .destructive) { dismiss() }
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark", role: .confirm) { submit() }
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
            Picker("Save To", selection: $target) {
                Text((store.inboxPath as NSString).deletingPathExtension).tag(String?.none)
                ForEach(store.sortedFiles.filter { $0.id != store.inboxPath && !$0.isPlaceholder }) { file in
                    Text(file.displayName).tag(String?.some(file.id))
                }
            }
        } label: {
            Label("Save To: \(target.flatMap { store.files[$0]?.displayName } ?? (store.inboxPath as NSString).deletingPathExtension)",
                  systemImage: "tray.and.arrow.down")
                .font(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 20)
        }
    }

    /// A notification for this entry, set like an alert in Reminders.
    @ViewBuilder private var notification: some View {
        HStack(spacing: 8) {
            if let date = notifyAt {
                Label("Reminder", systemImage: "bell.fill")
                    .foregroundStyle(.tint)
                Spacer()
                DatePicker("Reminder", selection: Binding { date } set: { notifyAt = $0 }, in: Date.now...)
                    .labelsHidden()
                Button("Remove Reminder", systemImage: "xmark.circle.fill") {
                    withAnimation(.snappy) { notifyAt = nil }
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    withAnimation(.snappy) { notifyAt = Self.nextHour() }
                } label: {
                    Label("Add Reminder", systemImage: "bell")
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
    }

    private static func nextHour(after now: Date = .now) -> Date {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: start) ?? now
    }

    private func inlineDatePicker(kind: PlanningKind, line: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            DatePicker(kind == .deadline ? "Deadline" : "Schedule", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
            HStack {
                Button("Cancel") { picking = nil }
                Spacer()
                Button("Done") {
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
        let notifyAt = notifyAt
        dismiss()
        Task {
            let saved = await store.capture(draft, into: target)
            if let saved, let notifyAt, let title = store.files[saved.fileID]?.document.headline(at: saved.line)?.title {
                TaskNotifications.shared.add(Reminder(fileID: saved.fileID, title: title, date: notifyAt))
            }
            // Confirm only once the file is written, so the haptic never claims a failed save.
            UINotificationFeedbackGenerator().notificationOccurred(saved == nil ? .error : .success)
        }
    }
}

extension PlanningKind: Identifiable {
    public var id: String { rawValue }
}
