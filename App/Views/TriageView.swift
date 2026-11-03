import OrgKit
import SwiftUI

/// Works through the inbox one card at a time. Each card is filed, turned
/// into a task, finished, deleted, or put off until later.
struct TriageView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var skipped: Set<String> = []
    @State private var moving: MoveRequest?
    @State private var drag: CGSize = .zero
    @State private var undo: DeletedEntry?
    @State private var handled = 0
    @State private var pickingDate: OrgHeadline?
    @State private var date = Date.now

    private var fileID: String { store.inboxPath }

    /// Open top-level entries of the inbox, minus the ones put off this session.
    private var queue: [OrgHeadline] {
        guard let document = store.files[fileID]?.document else { return [] }
        return document.headlines.filter { $0.level == 1 && !$0.isDone && !skipped.contains($0.identity) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                let queue = queue
                if let document = store.files[fileID]?.document, let current = queue.first {
                    Text("\(queue.count) left")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    stack(current, next: queue.dropFirst().prefix(2).map { $0 }, document: document)
                    actions(for: current, document: document)
                } else {
                    finished
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                UndoBanner(deleted: $undo) { store.restoreEntry($0.lines, in: fileID, at: $0.line) }
            }
            .sheet(item: $moving) { request in
                MoveSheet(request: request) { handled += 1 }
            }
            .sheet(item: $pickingDate) { headline in
                DatePickerSheet(title: "Schedule", date: date) { picked in
                    schedule(headline, on: OrgDate(picked))
                }
            }
            .sensoryFeedback(.success, trigger: handled)
            .animation(.snappy, value: queue.map(\.identity))
        }
    }

    // MARK: Cards

    private func stack(_ current: OrgHeadline, next: [OrgHeadline], document: OrgDocument) -> some View {
        ZStack {
            ForEach(Array(next.enumerated()).reversed(), id: \.element.identity) { depth, headline in
                TriageCard(headline: headline, document: document)
                    .scaleEffect(1 - CGFloat(depth + 1) * 0.04)
                    .offset(y: CGFloat(depth + 1) * 14)
                    .opacity(0.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TriageCard(headline: current, document: document)
                .overlay(alignment: .topLeading) { swipeHint }
                .offset(x: drag.width, y: drag.height * 0.2)
                .rotationEffect(.degrees(Double(drag.width) / 25))
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let width = value.translation.width
                            withAnimation(.snappy) { drag = .zero }
                            if width > 120 {
                                moving = MoveRequest(fileID: fileID, line: current.lineIndex)
                            } else if width < -120 {
                                delete(current, document: document)
                            }
                        }
                )
                .id(current.identity)
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .accessibilityAction(named: "Move") { moving = MoveRequest(fileID: fileID, line: current.lineIndex) }
                .accessibilityAction(named: "Delete") { delete(current, document: document) }
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder private var swipeHint: some View {
        if drag.width > 40 {
            hint("Move", symbol: "folder", tint: .indigo)
        } else if drag.width < -40 {
            hint("Delete", symbol: "trash", tint: .red)
        }
    }

    private func hint(_ title: LocalizedStringKey, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
            .padding(16)
            .opacity(min(1, abs(drag.width) / 120))
    }

    // MARK: Actions

    private func actions(for headline: OrgHeadline, document: OrgDocument) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ActionButton(title: "Move", symbol: "folder", tint: .indigo) {
                moving = MoveRequest(fileID: fileID, line: headline.lineIndex)
            }
            if headline.keyword == nil {
                Menu {
                    dateChoices(for: headline, makingTask: true)
                } label: {
                    ActionLabel(title: "Make To-do", symbol: "checkmark.circle", tint: .blue)
                }
            } else {
                Menu {
                    dateChoices(for: headline, makingTask: false)
                } label: {
                    ActionLabel(title: "Date", symbol: "calendar", tint: .blue)
                }
                ActionButton(title: "Done", symbol: "checkmark", tint: .green) {
                    store.edit(fileID) { $0.toggleDone(forHeadlineAt: headline.lineIndex) }
                    handled += 1
                }
            }
            ActionButton(title: "Delete", symbol: "trash", tint: .red) {
                delete(headline, document: document)
            }
            ActionButton(title: "Later", symbol: "arrow.uturn.down", tint: .gray) {
                withAnimation(.snappy) { _ = skipped.insert(headline.identity) }
            }
        }
    }

    @ViewBuilder private func dateChoices(for headline: OrgHeadline, makingTask: Bool) -> some View {
        if makingTask {
            Button("No Date", systemImage: "circle") { schedule(headline, on: nil) }
        }
        Button("Today", systemImage: "sun.max") { schedule(headline, on: OrgDate(.now)) }
        Button("Tomorrow", systemImage: "sunrise") { schedule(headline, on: OrgDate(.now).adding(days: 1)) }
        Button("Next Week", systemImage: "calendar.badge.clock") {
            let monday = Calendar.current.nextDate(after: .now, matching: DateComponents(weekday: 2),
                                                   matchingPolicy: .nextTime) ?? .now
            schedule(headline, on: OrgDate(monday))
        }
        Button("Choose Date…", systemImage: "calendar") {
            date = headline.scheduled?.date.date() ?? .now
            pickingDate = headline
        }
    }

    /// Makes the entry a task (if it is not yet) and sets its scheduled day.
    private func schedule(_ headline: OrgHeadline, on day: OrgDate?) {
        store.edit(fileID) { document in
            let line = headline.lineIndex
            if document.headline(at: line)?.keyword == nil {
                document.setKeyword(document.keywords.active.first, forHeadlineAt: line)
            }
            if let day {
                var timestamp = document.headline(at: line)?.scheduled ?? OrgTimestamp(date: day)
                timestamp.date = day
                document.setPlanning(.scheduled, to: timestamp, forHeadlineAt: line)
            }
        }
    }

    private func delete(_ headline: OrgHeadline, document: OrgDocument) {
        let title = headline.displayTitle
        guard let removed = store.deleteEntry(fileID, line: headline.lineIndex) else { return }
        handled += 1
        withAnimation(.snappy) { undo = DeletedEntry(lines: removed, line: headline.lineIndex, title: title) }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: handled)
                .accessibilityHidden(true)
            Text("All Sorted").font(.title2.bold())
            Text(skipped.isEmpty
                 ? "No unsorted memos."
                 : "The \(skipped.count) memos you put off will show again next time.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// One inbox entry, shown in full on a card.
private struct TriageCard: View {
    var headline: OrgHeadline
    var document: OrgDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let created = document.created(of: headline) {
                    Label(LivePreview.label(for: created, today: OrgDate(.now)), systemImage: "clock")
                }
                if headline.keyword != nil {
                    Label(headline.scheduled.map { DateLabel.short($0.date) } ?? "TODO",
                          systemImage: headline.scheduled == nil ? "checkmark.circle" : "calendar")
                        .foregroundStyle(.tint)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(headline.displayTitle.isEmpty ? String(localized: "Untitled") : headline.displayTitle)
                .font(.title2.weight(.bold))
                .lineLimit(3)

            let body = document.bodyLines(of: headline)
                .filter { line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    return !(OrgTimestamp.parse(text).map { !$0.isActive } ?? false)
                }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                Text(OrgInline.render(body))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            if !headline.tags.isEmpty {
                Text(headline.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 340, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ActionButton: View {
    var title: LocalizedStringKey
    var symbol: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) { ActionLabel(title: title, symbol: symbol, tint: tint) }
            .buttonStyle(.plain)
    }
}

private struct ActionLabel: View {
    var title: LocalizedStringKey
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
            Text(title)
                .font(.caption)
                // Explicit color: a Menu label would otherwise take the accent tint.
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
