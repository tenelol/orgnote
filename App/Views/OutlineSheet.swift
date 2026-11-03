import OrgKit
import SwiftUI

/// The file's headings as a navigable list, like a table of contents.
struct OutlineSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var fileID: String
    var onSelect: (Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let document = store.files[fileID]?.document {
                    ForEach(document.headlines) { headline in
                        Button {
                            onSelect(headline.lineIndex)
                        } label: {
                            HeadlineRow(headline: headline, indent: headline.level - 1) {
                                store.edit(fileID) { $0.toggleDone(forHeadlineAt: headline.lineIndex) }
                            }
                        }
                        .tint(.primary)
                        .accessibilityHint("Goes to this heading.")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One heading with a Reminders-style completion button when it is a task.
struct HeadlineRow: View {
    var headline: OrgHeadline
    var indent: Int = 0
    var subtitle: String?
    var trailing: String?
    var trailingIsAlert = false
    var onToggle: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Counts only taps here, so a change synced from the Mac never buzzes.
    @State private var taps = 0

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leading
            content
            Spacer(minLength: 0)
            if let trailing, !typeSize.isAccessibilitySize {
                Text(trailing)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(trailingIsAlert ? .red : .secondary)
            }
        }
        .padding(.leading, CGFloat(indent) * 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(headline.isDone ? .isSelected : [])
        .accessibilityAction(named: headline.isDone ? "Mark as Not Done" : "Mark as Done") { toggle() }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    @ViewBuilder private var leading: some View {
        if headline.keyword != nil {
            Button(action: toggle) {
                Image(systemName: headline.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(headline.isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            // Borderless keeps the button's own hit area inside a List row
            // instead of merging it with the row's navigation tap.
            .buttonStyle(.borderless)
            .padding(.leading, -10)
        } else {
            Image(systemName: headline.level == 1 ? "number" : "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 34)
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let priority = headline.priority {
                    Text(PriorityLabel.marks(priority))
                        .font(.body.weight(.bold))
                        .foregroundStyle(.red)
                }
                Text(headline.displayTitle.isEmpty ? String(localized: "Untitled") : headline.displayTitle)
                    .font(headline.level == 1 && headline.keyword == nil ? .headline : .body)
                    .strikethrough(headline.isDone, color: .secondary)
                    .foregroundStyle(headline.isDone ? .secondary : .primary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
            let details = detailText(spoken: false)
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            if let trailing, typeSize.isAccessibilitySize {
                Text(trailing)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(trailingIsAlert ? .red : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func toggle() {
        taps += 1
        onToggle()
    }

    private func detailText(spoken: Bool) -> String {
        var parts: [String] = []
        if let subtitle { parts.append(subtitle) }
        if headline.checkboxes.total > 0 {
            parts.append(spoken
                ? String(localized: "\(headline.checkboxes.done) of \(headline.checkboxes.total) checked")
                : "☑︎ \(headline.checkboxes.done)/\(headline.checkboxes.total)")
        }
        if subtitle == nil {
            if let scheduled = headline.scheduled { parts.append(String(localized: "Scheduled \(DateLabel.short(scheduled.date))")) }
            if let deadline = headline.deadline { parts.append(String(localized: "Due \(DateLabel.short(deadline.date))")) }
        }
        parts += headline.tags.map { spoken ? String(localized: "Tag \($0)") : "#\($0)" }
        return parts.joined(separator: spoken ? Self.spokenSeparator : "  ")
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if headline.keyword != nil { parts.append(headline.isDone ? String(localized: "Done") : String(localized: "Not Done")) }
        if let priority = headline.priority { parts.append(String(localized: "\(PriorityLabel.spoken(priority)) priority")) }
        parts.append(headline.displayTitle.isEmpty ? String(localized: "Untitled") : headline.displayTitle)
        if let trailing { parts.append(trailingIsAlert ? String(localized: "\(trailing), overdue") : trailing) }
        let details = detailText(spoken: true)
        if !details.isEmpty { parts.append(details) }
        return parts.joined(separator: Self.spokenSeparator)
    }

    private static var spokenSeparator: String {
        String(localized: ", ", comment: "Separates the parts of a row read by VoiceOver.")
    }
}

enum PriorityLabel {
    /// Reminders shows priority as exclamation marks; A is the highest in Org.
    static func marks(_ priority: String) -> String {
        switch priority.uppercased() {
        case "A": "!!!"
        case "B": "!!"
        default: "!"
        }
    }

    static func spoken(_ priority: String) -> String {
        switch priority.uppercased() {
        case "A": String(localized: "High")
        case "B": String(localized: "Medium")
        default: String(localized: "Low")
        }
    }
}

enum DateLabel {
    static func short(_ date: OrgDate, today: OrgDate = OrgDate(.now)) -> String {
        switch today.days(until: date) {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default:
            return date.date().formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
        }
    }
}

/// The same task actions as the swipe actions, for long press and VoiceOver.
struct TaskActions: View {
    @Environment(LibraryStore.self) private var store
    var fileID: String
    var headline: OrgHeadline

    var body: some View {
        if headline.keyword != nil {
            Button(headline.isDone ? "Mark as Not Done" : "Mark as Done",
                   systemImage: headline.isDone ? "arrow.uturn.backward" : "checkmark.circle") {
                store.edit(fileID) { $0.toggleDone(forHeadlineAt: headline.lineIndex) }
            }
            if !headline.isDone {
                Button("Move to Today", systemImage: "sun.max") { Self.reschedule(store, fileID, headline, days: 0) }
                Button("Postpone to Tomorrow", systemImage: "sunrise") { Self.reschedule(store, fileID, headline, days: 1) }
            }
        }
    }

    static func reschedule(_ store: LibraryStore, _ fileID: String, _ headline: OrgHeadline, days: Int) {
        let date = OrgDate(.now).adding(days: days)
        store.edit(fileID) { document in
            let line = headline.lineIndex
            guard let current = document.headline(at: line) else { return }
            // Keep any time or repeater; only the day moves.
            var timestamp = current.scheduled ?? OrgTimestamp(date: date)
            timestamp.date = date
            document.setPlanning(.scheduled, to: timestamp, forHeadlineAt: line)
        }
    }
}

/// Leading complete and trailing reschedule swipes, shared by Agenda and TODO.
struct TaskSwipeActions: ViewModifier {
    @Environment(LibraryStore.self) private var store
    var fileID: String
    var headline: OrgHeadline

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                if headline.keyword != nil {
                    Button(headline.isDone ? "Mark as Not Done" : "Mark as Done",
                           systemImage: headline.isDone ? "arrow.uturn.backward" : "checkmark") {
                        store.edit(fileID) { $0.toggleDone(forHeadlineAt: headline.lineIndex) }
                    }
                    .tint(.accentColor)
                }
            }
            .swipeActions(edge: .trailing) {
                if headline.keyword != nil, !headline.isDone {
                    Button("Postpone to Tomorrow", systemImage: "sunrise") {
                        TaskActions.reschedule(store, fileID, headline, days: 1)
                    }
                    .tint(.orange)
                    Button("Move to Today", systemImage: "sun.max") {
                        TaskActions.reschedule(store, fileID, headline, days: 0)
                    }
                    .tint(.blue)
                }
            }
            .contextMenu { TaskActions(fileID: fileID, headline: headline) }
    }
}

extension View {
    func taskActions(fileID: String, headline: OrgHeadline) -> some View {
        modifier(TaskSwipeActions(fileID: fileID, headline: headline))
    }
}
