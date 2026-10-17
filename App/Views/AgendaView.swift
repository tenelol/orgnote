import OrgKit
import SwiftUI

/// Days at a glance: a freely scrolling strip of days with dots, today's
/// progress ring, and the chosen day split into all-day items and a timeline.
struct AgendaView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(NotebookStyles.self) private var styles
    @State private var selected = OrgDate(.now)
    @State private var showsOverdue = true

    private var today: OrgDate { OrgDate(.now) }
    /// How far the strip reaches either side of today.
    private static let reach = 180

    var body: some View {
        let first = today.adding(days: -Self.reach)
        let span = store.agenda(from: first, days: Self.reach * 2 + 1)
        let byDay = Dictionary(uniqueKeysWithValues: span.days.map { ($0.date, $0.items) })
        let overdue = store.agenda(from: today, days: 1).overdue
        let day = byDay[selected] ?? []
        let allDay = day.filter { $0.time == nil }
        let timed = day.filter { $0.time != nil }

        List {
            if selected == today, !overdue.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsOverdue) {
                        ForEach(overdue) { item in
                            row(item, trailing: DateLabel.short(item.date), alert: true)
                        }
                    } label: {
                        Label("期限切れ \(overdue.count)件", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                .listRowBackground(Color.red.opacity(0.1))
            }

            if !allDay.isEmpty {
                Section("終日") {
                    ForEach(allDay) { item in
                        row(item, trailing: item.kind == .deadline ? "期限" : nil,
                            alert: item.kind == .deadline && !item.headline.isDone)
                    }
                }
            }

            if !timed.isEmpty {
                Section("時間") {
                    ForEach(timed) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Text(item.time?.string ?? "")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                                .padding(.top, 12)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: item.fileID))
                                .frame(width: 4)
                                .padding(.vertical, 6)
                                .accessibilityHidden(true)
                            row(item, trailing: nil, alert: false, showsDot: false)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                    }
                }
            }

            if day.isEmpty, !(selected == today && !overdue.isEmpty) {
                Section {
                    ContentUnavailableView {
                        Label(selected == today ? "今日の予定はありません" : "予定はありません", systemImage: "sun.max")
                    } description: {
                        Text("TODOに予定日や期限を付けると、ここに並びます。")
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Pinned above the list, as in Calendar; inside a row, list updates would cross-fade the slide.
        .safeAreaInset(edge: .top, spacing: 0) {
            DayStrip(dates: (0...(Self.reach * 2)).map { first.adding(days: $0) },
                     selected: $selected, today: today, items: byDay)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .navigationTitle(title)
        .navigationSubtitle(selected.date().formatted(.dateTime.month().day().weekday(.wide)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ProgressRing(done: progress.done, total: progress.total)
            }
            if selected != today {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今日") { withAnimation(.snappy) { selected = today } }
                }
            }
        }
        .refreshable { await store.refresh() }
    }

    private var title: String {
        switch today.days(until: selected) {
        case 0: "今日"
        case 1: "明日"
        case -1: "昨日"
        default: "アジェンダ"
        }
    }

    /// Today's tasks done out of all of today's tasks, overdue ones included.
    private var progress: (done: Int, total: Int) {
        let agenda = store.agenda(from: today, days: 1)
        let tasks = (agenda.overdue + (agenda.days.first?.items ?? [])).filter { $0.headline.keyword != nil }
        return (tasks.filter(\.headline.isDone).count, tasks.count)
    }

    private func color(for fileID: String) -> Color {
        styles.style(for: fileID, isCaptureTarget: fileID == store.inboxPath).tint
    }

    private func row(_ item: AgendaItem, trailing: String?, alert: Bool, showsDot: Bool = true) -> some View {
        NavigationLink(value: Route.entry(item.fileID, line: item.headline.lineIndex)) {
            HStack(spacing: 0) {
                if showsDot {
                    Circle().fill(color(for: item.fileID)).frame(width: 7, height: 7)
                        .padding(.trailing, 2)
                        .accessibilityHidden(true)
                }
                HeadlineRow(headline: item.headline, subtitle: subtitle(item), trailing: trailing, trailingIsAlert: alert) {
                    withAnimation(.snappy) {
                        store.edit(item.fileID) { $0.toggleDone(forHeadlineAt: item.headline.lineIndex) }
                    }
                }
            }
        }
        .taskActions(fileID: item.fileID, headline: item.headline)
    }

    /// Where the entry lives: the notebook and, if any, the heading above it.
    private func subtitle(_ item: AgendaItem) -> String {
        guard let file = store.files[item.fileID] else { return item.fileID }
        let parent = file.document.headlines.last {
            $0.lineIndex < item.headline.lineIndex && $0.subtreeEndLineIndex > item.headline.lineIndex
        }
        return [file.displayName, parent?.displayTitle].compactMap { $0 }.joined(separator: " › ")
    }
}

/// A strip of days that scrolls freely with momentum and settles on a day
/// boundary. Seven days fit the width; a dot marks days with something on.
private struct DayStrip: View {
    var dates: [OrgDate]
    @Binding var selected: OrgDate
    var today: OrgDate
    var items: [OrgDate: [AgendaItem]]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Eager on purpose: a lazy stack here, inside the list's top inset, drew nothing.
                HStack(spacing: 0) {
                    ForEach(dates, id: \.self) { date in
                        day(date)
                            .frame(width: Self.cellWidth)
                            .id(date)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(height: 72)
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            // A tapped day, or the Today button, glides to the center.
            .onChange(of: selected) { _, date in withAnimation(.snappy) { proxy.scrollTo(date, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    /// Seven days across a phone screen.
    private static var cellWidth: CGFloat {
        let width = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        return (width - 48) / 7
    }

    private func day(_ date: OrgDate) -> some View {
        let items = items[date] ?? []
        return Button {
            withAnimation(.snappy) { selected = date }
        } label: {
            VStack(spacing: 4) {
                Text(date.day == 1 ? date.date().formatted(.dateTime.month(.abbreviated)) : date.date().formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(date.day == 1 ? Color.accentColor : Color.secondary)
                Text("\(date.day)")
                    .font(.body.weight(date == selected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(foreground(date))
                    .frame(width: 34, height: 34)
                    .background {
                        if date == selected { Circle().fill(date == today ? Color.accentColor : Color.primary) }
                    }
                Circle().fill(dot(items)).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.date().formatted(.dateTime.month().day().weekday(.wide))
            + (items.isEmpty ? "" : "、\(items.count)件"))
        .accessibilityAddTraits(date == selected ? .isSelected : [])
    }

    private func foreground(_ date: OrgDate) -> Color {
        if date == selected { return Color(.systemBackground) }
        return date == today ? .accentColor : .primary
    }

    private func dot(_ items: [AgendaItem]) -> Color {
        if items.isEmpty { return .clear }
        if items.contains(where: { $0.kind == .deadline && !$0.headline.isDone }) { return .red }
        return items.allSatisfy(\.headline.isDone) ? Color(.tertiaryLabel) : .accentColor
    }
}

/// Today's tasks as a filling ring, like Fitness.
private struct ProgressRing: View {
    var done: Int
    var total: Int

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: fraction)
            Text(total == 0 ? "–" : "\(done)/\(total)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
        }
        .frame(width: 30, height: 30)
        .accessibilityElement()
        .accessibilityLabel("今日のTODO \(total)件中\(done)件完了")
    }
}
