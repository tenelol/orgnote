import OrgKit
import SwiftUI

/// The quick-capture sheet. The first line becomes the heading and the rest
/// its body, like the title line of a note in Notes.
struct CaptureView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// The default from Settings; this sheet only reads it.
    @AppStorage("captureAsTodo") private var defaultTodo = false
    @State private var asTodo = false
    @State private var text = ""
    @State private var scheduled: OrgDate?
    @State private var deadline: OrgDate?
    @State private var priority: String?
    @State private var tagText = ""
    @State private var target: String?
    /// The date being picked inline; a second sheet on top of this one would break HIG.
    @State private var picking: PlanningKind?
    @State private var pickedDate = Date.now
    @State private var confirmingDiscard = false

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CaptureTextView(text: $text, placeholder: "1行目が見出しになります")
                    options
                    if let picking {
                        inlineDatePicker(picking)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .animation(.snappy, value: picking)
            }
            .scrollDismissesKeyboard(.never)
            .navigationTitle(asTodo ? "新規TODO" : "新規メモ")
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
            asTodo = defaultTodo || router.captureStartsAsTodo
            router.captureStartsAsTodo = false
            if let requested = router.captureTarget, requested != store.inboxPath { target = requested }
            router.captureTarget = nil
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Toggle(isOn: $asTodo) {
                        ChipLabel(title: "TODO", symbol: asTodo ? "checkmark.circle.fill" : "circle", isOn: asTodo)
                    }
                    .toggleStyle(.chip)
                    dateChip(.scheduled, value: scheduled, symbol: "calendar", empty: "予定日")
                    dateChip(.deadline, value: deadline, symbol: "flag", empty: "期限")
                    Menu {
                        Picker("優先度", selection: $priority) {
                            Text("なし").tag(String?.none)
                            Text("高").tag(String?.some("A"))
                            Text("中").tag(String?.some("B"))
                            Text("低").tag(String?.some("C"))
                        }
                    } label: {
                        ChipLabel(title: priority.map { "優先度 \(PriorityLabel.spoken($0))" } ?? "優先度",
                                  symbol: "exclamationmark", isOn: priority != nil)
                    }
                    .accessibilityAddTraits(priority != nil ? .isSelected : [])
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()

            HStack(spacing: 8) {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("タグ（スペース区切り）", text: $tagText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("タグ")
            }
            .font(.subheadline)
            .frame(minHeight: 44)

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
                    .frame(minHeight: 44)
            }
        }
    }

    private func inlineDatePicker(_ kind: PlanningKind) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            DatePicker(kind == .deadline ? "期限" : "予定日", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
            Button("完了") {
                set(kind, OrgDate(pickedDate))
                picking = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func dateChip(_ kind: PlanningKind, value: OrgDate?, symbol: String, empty: String) -> some View {
        Menu {
            Button("今日", systemImage: "sun.max") { set(kind, OrgDate(.now)) }
            Button("明日", systemImage: "sunrise") { set(kind, OrgDate(.now).adding(days: 1)) }
            Button("日付を選択…", systemImage: "calendar") {
                pickedDate = value?.date() ?? .now
                picking = kind
            }
            if value != nil {
                Button("日付を外す", systemImage: "xmark.circle", role: .destructive) { set(kind, nil) }
            }
        } label: {
            ChipLabel(title: value.map { "\(empty) \(DateLabel.short($0))" } ?? empty, symbol: symbol, isOn: value != nil,
                      tint: kind == .deadline ? .red : nil)
        }
        .accessibilityAddTraits(value != nil ? .isSelected : [])
    }

    private func set(_ kind: PlanningKind, _ date: OrgDate?) {
        if kind == .deadline { deadline = date } else { scheduled = date }
        // A dated entry only shows up in the agenda as a task, so dating implies TODO.
        if date != nil { asTodo = true }
    }

    private func submit() {
        guard !isEmpty else { return }
        let tags = tagText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ":" })
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : String($0) }
            .filter { !$0.isEmpty }
        var body = text
        // The priority cookie sits between the keyword and the title, so it leads the first line.
        if let priority { body = "[#\(priority)] " + body }
        let keyword = asTodo ? "TODO" : nil
        let scheduled = scheduled.map { OrgTimestamp(date: $0) }
        let deadline = deadline.map { OrgTimestamp(date: $0) }
        let target = target
        dismiss()
        Task {
            let saved = await store.capture(body, keyword: keyword, scheduled: scheduled,
                                            deadline: deadline, tags: tags, into: target)
            // Confirm only once the file is written, so the haptic never claims a failed save.
            UINotificationFeedbackGenerator().notificationOccurred(saved == nil ? .error : .success)
        }
    }
}

extension PlanningKind: Identifiable {
    public var id: String { rawValue }
}

/// A capsule toggle; keeps the switch semantics for VoiceOver.
private struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

private extension ToggleStyle where Self == ChipToggleStyle {
    static var chip: ChipToggleStyle { ChipToggleStyle() }
}

private struct ChipLabel: View {
    var title: String
    var symbol: String
    var isOn: Bool
    var tint: Color?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            // Explicit colors: Menu labels would otherwise pick up the accent tint.
            .foregroundStyle(isOn ? (tint ?? .accentColor) : Color(.secondaryLabel))
            .background(
                isOn ? AnyShapeStyle((tint ?? .accentColor).opacity(0.15)) : AnyShapeStyle(.fill.tertiary),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}
